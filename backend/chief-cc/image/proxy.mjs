// The model forward of a Cloud Chief VM (chief-brain-cc/, backend/chief-cc/bake.sh). It runs as user
// `ccproxy` on 127.0.0.1:4017 and is the only way out to the tailnet: the `chief` user (Claude Code)
// has every tailnet address refused by nftables (boot.sh). It forwards only the Messages calls of Claude
// Code to the sr2 gateway (/etc/chief-cc/upstream), streamed both ways; every other path is 403, so the
// gateway's operator endpoints are out of reach from the agent. It holds no secret: the gateway
// authenticates this VM by its tailnet identity.
import http from "node:http"
import { readFileSync } from "node:fs"

const upstream = new URL(readFileSync("/etc/chief-cc/upstream", "utf8").trim())
const ALLOWED = new Set(["/v1/messages", "/v1/messages/count_tokens"])
const HOP = new Set(["host", "connection", "keep-alive", "transfer-encoding", "upgrade", "proxy-connection", "te", "trailer"])

http
  .createServer((req, res) => {
    const url = new URL(req.url ?? "/", "http://local")
    if (req.method !== "POST" || !ALLOWED.has(url.pathname)) {
      res.writeHead(403, { "content-type": "application/json" })
      return res.end(JSON.stringify({ type: "error", error: { type: "permission_error", message: "only POST /v1/messages leaves this machine" } }))
    }
    const headers = Object.fromEntries(Object.entries(req.headers).filter(([k]) => !HOP.has(k.toLowerCase())))
    const out = http.request({ host: upstream.hostname, port: upstream.port || 80, method: "POST", path: url.pathname + url.search, headers }, (up) => {
      res.writeHead(up.statusCode ?? 502, Object.fromEntries(Object.entries(up.headers).filter(([k]) => !HOP.has(k.toLowerCase()))))
      up.pipe(res)
    })
    out.on("error", (e) => {
      if (!res.headersSent) res.writeHead(502, { "content-type": "application/json" })
      res.end(JSON.stringify({ type: "error", error: { type: "api_error", message: `gateway unreachable: ${e.code ?? "error"}` } }))
    })
    req.pipe(out)
  })
  .listen(4017, "127.0.0.1")
