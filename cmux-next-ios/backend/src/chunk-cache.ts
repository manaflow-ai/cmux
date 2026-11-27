import { DurableObject } from "cloudflare:workers"
import type { Env } from "./env.ts"
import { RELAY_BUCKETS } from "./link-relay.ts"

export const CHUNK_ID = /^[0-9a-f]{64}$/
export const CHUNK_MAX_BYTES = 256 * 1024 + 64
export const CHUNK_MAX_IDS = 1024
export const CHUNK_BATCH_MAX_BODY_BYTES = 72 * 1024
export const CHUNK_CACHE_BYTES = 64 * 1024 * 1024
export const CHUNK_TTL_MS = 7 * 24 * 60 * 60 * 1000

export const chunkPairName = (ownerKey: string, space: string, first: string, second: string) => {
  const [a, b] = [first, second].sort()
  return `${space ? `${space}|` : ""}chunks:${ownerKey}:${a}:${b}`
}

type Bucket = { tokens: number; at: number }
type PairBuckets = { frames: Bucket; bytes: Bucket }

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } })
const bad = (message: string) => json({ error: { code: "bad_request", message } }, 400)

const parseIds = (body: unknown): string[] | undefined => {
  if (!body || typeof body !== "object" || Array.isArray(body)) return undefined
  const ids = (body as { ids?: unknown }).ids
  if (!Array.isArray(ids) || ids.length > CHUNK_MAX_IDS || !ids.every((id) => typeof id === "string" && CHUNK_ID.test(id))) return undefined
  return ids
}

export class ChunkCache extends DurableObject<Env> {
  private readonly buckets = new Map<string, PairBuckets>()
  private readonly touches = new Map<string, number>()

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env)
    ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS chunks (
      id TEXT PRIMARY KEY, data BLOB NOT NULL, size INTEGER NOT NULL,
      created_at INTEGER NOT NULL, last_read_at INTEGER NOT NULL, expires_at INTEGER NOT NULL
    )`)
  }

  override async fetch(req: Request): Promise<Response> {
    const device = req.headers.get("x-cmux-chunk-device") ?? ""
    if (!device) return bad("missing chunk device")
    const raw = req.method === "PUT" || req.method === "POST" ? await req.arrayBuffer() : undefined
    if (!this.take(device, raw?.byteLength ?? 0)) return new Response("rate limited", { status: 429, headers: { "retry-after": "60" } })
    const path = new URL(req.url).pathname
    if (req.method === "PUT") return this.put(path, raw!)
    if (req.method === "GET") return this.get(path, device)
    let parsed: unknown
    if (raw) {
      try {
        parsed = JSON.parse(new TextDecoder().decode(raw))
      } catch {
        parsed = undefined
      }
    }
    if (req.method === "POST" && path === "/have") return this.have(parsed)
    if (req.method === "POST" && path === "/get") return this.batchGet(parsed, device)
    return new Response("not found", { status: 404 })
  }

  override async alarm(): Promise<void> {
    const now = Date.now()
    this.ctx.storage.sql.exec(`DELETE FROM chunks WHERE expires_at <= ?`, now)
    const next = this.ctx.storage.sql.exec<{ expires_at: number }>(`SELECT MIN(expires_at) AS expires_at FROM chunks`).toArray()[0]?.expires_at
    if (next !== null && next !== undefined) await this.ctx.storage.setAlarm(next)
  }

  private put(path: string, data: ArrayBuffer): Response {
    const id = path.split("/").pop() ?? ""
    if (!CHUNK_ID.test(id)) return bad("chunk id must be 64 lowercase hexadecimal characters")
    if (data.byteLength > CHUNK_MAX_BYTES) return new Response("chunk too large", { status: 413 })
    const now = Date.now()
    this.flushTouches()
    const existing = this.ctx.storage.sql.exec<{ id: string }>(`SELECT id FROM chunks WHERE id = ? AND expires_at > ?`, id, now).toArray()[0]
    if (existing) return json({ stored: false }, 200)
    this.ctx.storage.sql.exec(`DELETE FROM chunks WHERE expires_at <= ?`, now)
    let used = Number(this.ctx.storage.sql.exec<{ total: number | null }>(`SELECT SUM(size) AS total FROM chunks`).toArray()[0]?.total ?? 0)
    const victims = this.ctx.storage.sql.exec<{ id: string; size: number }>(`SELECT id, size FROM chunks ORDER BY last_read_at ASC, created_at ASC`).toArray()
    for (const victim of victims) {
      if (used + data.byteLength <= CHUNK_CACHE_BYTES) break
      this.ctx.storage.sql.exec(`DELETE FROM chunks WHERE id = ?`, victim.id)
      used -= victim.size
    }
    if (data.byteLength > CHUNK_CACHE_BYTES) return new Response("chunk too large", { status: 413 })
    this.ctx.storage.sql.exec(`INSERT INTO chunks (id, data, size, created_at, last_read_at, expires_at) VALUES (?, ?, ?, ?, ?, ?)`, id, data, data.byteLength, now, now, now + CHUNK_TTL_MS)
    const next = this.ctx.storage.sql.exec<{ expires_at: number }>(`SELECT MIN(expires_at) AS expires_at FROM chunks`).toArray()[0]?.expires_at
    if (next !== null && next !== undefined) void this.ctx.storage.setAlarm(next)
    return json({ stored: true }, 201)
  }

  private get(path: string, device: string): Response {
    const id = path.split("/").pop() ?? ""
    if (!CHUNK_ID.test(id)) return bad("chunk id must be 64 lowercase hexadecimal characters")
    const row = this.ctx.storage.sql.exec<{ data: ArrayBuffer; expires_at: number }>(`SELECT data, expires_at FROM chunks WHERE id = ?`, id).toArray()[0]
    if (!row || row.expires_at <= Date.now()) return new Response(null, { status: 404 })
    if (!this.takeBytes(device, row.data.byteLength)) return new Response("rate limited", { status: 429, headers: { "retry-after": "60" } })
    this.touch(id)
    return new Response(row.data, { headers: { "content-type": "application/octet-stream", "cache-control": "no-store" } })
  }

  private have(body: unknown): Response {
    const ids = parseIds(body)
    if (!ids) return bad(`body must be {ids:[up to ${CHUNK_MAX_IDS} lowercase chunk ids]}`)
    const now = Date.now()
    const have = ids.map((id) => !!this.ctx.storage.sql.exec<{ id: string }>(`SELECT id FROM chunks WHERE id = ? AND expires_at > ?`, id, now).toArray()[0])
    return json({ have })
  }

  private batchGet(body: unknown, device: string): Response {
    const ids = parseIds(body)
    if (!ids) return bad(`body must be {ids:[up to ${CHUNK_MAX_IDS} lowercase chunk ids]}`)
    const now = Date.now()
    let total = 0
    for (const id of ids) {
      const row = this.ctx.storage.sql.exec<{ size: number; expires_at: number }>(`SELECT size, expires_at FROM chunks WHERE id = ?`, id).toArray()[0]
      if (row && row.expires_at > now) total += 36 + row.size
    }
    if (!this.takeBytes(device, total)) return new Response("rate limited", { status: 429, headers: { "retry-after": "60" } })
    const out: Uint8Array[] = []
    const present: string[] = []
    for (const id of ids) {
      const row = this.ctx.storage.sql.exec<{ data: ArrayBuffer; expires_at: number }>(`SELECT data, expires_at FROM chunks WHERE id = ?`, id).toArray()[0]
      if (!row || row.expires_at <= now) continue
      const bytes = new Uint8Array(row.data)
      const record = new Uint8Array(32 + 4 + bytes.byteLength)
      record.set(Uint8Array.from(id.match(/../g)!, (h) => Number.parseInt(h, 16)))
      new DataView(record.buffer).setUint32(32, bytes.byteLength)
      record.set(bytes, 36)
      out.push(record)
      present.push(id)
    }
    const responseBytes = out.reduce((n, part) => n + part.byteLength, 0)
    for (const id of present) this.touch(id)
    const result = new Uint8Array(responseBytes)
    let at = 0
    for (const part of out) {
      result.set(part, at)
      at += part.byteLength
    }
    return new Response(result, { headers: { "content-type": "application/octet-stream", "cache-control": "no-store" } })
  }

  private touch(id: string) {
    this.touches.set(id, Date.now())
    if (this.touches.size >= 32) this.flushTouches()
  }

  private flushTouches() {
    for (const [id, at] of this.touches) this.ctx.storage.sql.exec(`UPDATE chunks SET last_read_at = ? WHERE id = ?`, at, id)
    this.touches.clear()
  }

  private take(device: string, bytes: number): boolean {
    const now = Date.now()
    let pair = this.buckets.get(device)
    if (!pair) {
      pair = { frames: { tokens: RELAY_BUCKETS.frames.burst, at: now }, bytes: { tokens: RELAY_BUCKETS.bytes.burst, at: now } }
      this.buckets.set(device, pair)
    }
    const refill = (bucket: Bucket, spec: { rate: number; burst: number }) => {
      bucket.tokens = Math.min(spec.burst, bucket.tokens + ((now - bucket.at) / 1000) * spec.rate)
      bucket.at = now
    }
    refill(pair.frames, RELAY_BUCKETS.frames)
    refill(pair.bytes, RELAY_BUCKETS.bytes)
    if (pair.frames.tokens < 1 || pair.bytes.tokens < bytes) return false
    pair.frames.tokens -= 1
    pair.bytes.tokens -= bytes
    return true
  }

  private takeBytes(device: string, bytes: number): boolean {
    const pair = this.buckets.get(device)
    if (!pair) return false
    const now = Date.now()
    pair.bytes.tokens = Math.min(RELAY_BUCKETS.bytes.burst, pair.bytes.tokens + ((now - pair.bytes.at) / 1000) * RELAY_BUCKETS.bytes.rate)
    pair.bytes.at = now
    if (pair.bytes.tokens < bytes) return false
    pair.bytes.tokens -= bytes
    return true
  }
}
