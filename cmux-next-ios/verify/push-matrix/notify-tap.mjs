// A transparent pass-through to the dev Worker for the rig Mac's cmux-mobile-host
// (CMUX_NEXT_MOBILE_API_URL=http://127.0.0.1:PORT, a Debug launch variable). Every
// request and WebSocket goes on to the real Worker unchanged; the body and answer of
// each POST /v1/devices/:mac/notify are appended to OUT (JSON lines) so the payloads
// the real Mac host produced can be pushed into a simulator. Never logs headers.
//   node notify-tap.mjs PORT OUT [UPSTREAM]
import http from "node:http"
import tls from "node:tls"
import net from "node:net"
import fs from "node:fs"

const [port, out, upstream = "https://cmux-mobile-api-dev.debussy.workers.dev"] = process.argv.slice(2)
const up = new URL(upstream)

const server = http.createServer(async (req, res) => {
  const chunks = []
  for await (const c of req) chunks.push(c)
  const body = Buffer.concat(chunks)
  const headers = { ...req.headers, host: up.host }
  delete headers["content-length"]
  delete headers["connection"]
  try {
    const r = await fetch(new URL(req.url, upstream), { method: req.method, headers, body: body.length ? body : undefined })
    const answer = Buffer.from(await r.arrayBuffer())
    // A phone's sealed mailbox reply (ciphertext only), kept so the rig can replay it as a
    // malicious service would (verify/push-matrix.md, PR B rows).
    if (req.method === "POST" && /^\/v1\/devices\/[^/]+\/mailbox$/.test(req.url)) {
      let item = null
      try { item = JSON.parse(body.toString()) } catch {}
      fs.appendFileSync(out.replace(/\.jsonl$/, "") + "-mailbox.jsonl", JSON.stringify({ at: Date.now(), mac: req.url.split("/")[3], status: r.status, item }) + "\n")
    }
    if (req.method === "POST" && /^\/v1\/devices\/[^/]+\/notify$/.test(req.url)) {
      let event = null, result = null
      try { event = JSON.parse(body.toString()) } catch {}
      try { result = JSON.parse(answer.toString()) } catch {}
      fs.appendFileSync(out, JSON.stringify({ at: Date.now(), mac: req.url.split("/")[3], status: r.status, event, result }) + "\n")
    }
    const h = {}
    r.headers.forEach((v, k) => { if (!["content-encoding", "content-length", "transfer-encoding", "connection"].includes(k)) h[k] = v })
    res.writeHead(r.status, h).end(answer)
  } catch (e) {
    res.writeHead(502).end(String(e))
  }
})

// WebSocket upgrades: a raw pipe (TLS for https, plain TCP for a local http Worker) to the
// Worker with the same request line and headers.
server.on("upgrade", (req, socket, head) => {
  const plain = up.protocol === "http:"
  const connect = (ready) =>
    plain
      ? net.connect({ host: up.hostname, port: Number(up.port || 80) }, ready)
      : tls.connect({ host: up.hostname, port: Number(up.port || 443), servername: up.hostname }, ready)
  const remote = connect(() => {
    const lines = [`${req.method} ${req.url} HTTP/1.1`]
    for (let i = 0; i < req.rawHeaders.length; i += 2) {
      const k = req.rawHeaders[i]
      lines.push(`${k}: ${k.toLowerCase() === "host" ? up.host : req.rawHeaders[i + 1]}`)
    }
    remote.write(lines.join("\r\n") + "\r\n\r\n")
    if (head.length) remote.write(head)
    socket.pipe(remote).pipe(socket)
  })
  const end = () => { socket.destroy(); remote.destroy() }
  remote.on("error", end); socket.on("error", end); remote.on("close", end); socket.on("close", end)
})

server.listen(Number(port), "127.0.0.1", () => console.log(`notify-tap on 127.0.0.1:${port} -> ${upstream}`))
