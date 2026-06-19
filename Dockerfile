# Self-contained build for Vessl (and any single `docker build`).
# memos' own scripts/Dockerfile is backend-only and assumes the frontend was
# already built in CI (`pnpm release`) — the committed repo only ships a 244-byte
# stub dist, so a from-source build yields a blank UI. This adds a frontend
# stage that builds web/ and feeds the result into the Go embed before compiling.

# ── 1. Frontend: build web/ → server/router/frontend/dist ────────────────────
FROM node:22-alpine AS frontend
WORKDIR /src
RUN npm install -g pnpm@11.0.1
COPY . .
WORKDIR /src/web
RUN pnpm install --frozen-lockfile
RUN pnpm release

# ── 2. Backend: compile memos with the real frontend embedded ────────────────
FROM --platform=$BUILDPLATFORM golang:1.26.2-alpine AS backend
WORKDIR /backend-build
RUN apk add --no-cache git ca-certificates
COPY go.mod go.sum ./
RUN go mod download
COPY . .
COPY --from=frontend /src/server/router/frontend/dist ./server/router/frontend/dist
ARG TARGETOS TARGETARCH VERSION=dev COMMIT=unknown
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath \
      -ldflags="-s -w -X github.com/usememos/memos/internal/version.Version=${VERSION} -X github.com/usememos/memos/internal/version.Commit=${COMMIT} -extldflags '-static'" \
      -tags netgo,osusergo -o memos ./cmd/memos

# ── 3. Runtime (mirrors scripts/Dockerfile's monolithic stage) ───────────────
FROM alpine:3.21 AS monolithic
RUN apk add --no-cache tzdata ca-certificates su-exec && \
    addgroup -g 10001 -S nonroot && \
    adduser -u 10001 -S -G nonroot -h /var/opt/memos nonroot && \
    mkdir -p /var/opt/memos /usr/local/memos && \
    chown -R nonroot:nonroot /var/opt/memos
COPY --from=backend /backend-build/memos /usr/local/memos/memos
COPY --from=backend --chmod=755 /backend-build/scripts/entrypoint.sh /usr/local/memos/entrypoint.sh
USER root
WORKDIR /var/opt/memos
VOLUME /var/opt/memos
ENV TZ="UTC" \
    MEMOS_PORT="5230"
EXPOSE 5230
ENTRYPOINT ["/usr/local/memos/entrypoint.sh", "/usr/local/memos/memos"]
