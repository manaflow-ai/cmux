import { env, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test"
import { describe, expect, it } from "vitest"
import { CHUNK_CACHE_BYTES, CHUNK_MAX_BYTES, CHUNK_TTL_MS } from "../src/chunk-cache.ts"
import { chunkPairName } from "../src/chunk-cache.ts"
import { worker, token, register, connect, type Sock } from "./helpers.ts"

const id = (n: number) => n.toString(16).padStart(2, "0").repeat(32)
const bytes = (n: number, value = 7) => new Uint8Array(n).fill(value)

const pair = async (user = "chunk-user") => {
  const tok = await token(user)
  const phone = await register(tok, "phone", `personal-${user}`)
  const mac = await register(tok, "mac", `personal-${user}`)
  const p = await connect(tok, `personal-${user}`, phone)
  const m = await connect(tok, `personal-${user}`, mac)
  await Promise.all([p.until((s) => s.frames.some((f) => f.type === "hello")), m.until((s) => s.frames.some((f) => f.type === "hello"))])
  const sessionId = crypto.randomUUID()
  p.send({ type: "signal", to: mac, from: phone, sessionId, payload: { kind: "wg-init", publicKey: "k", endpoints: [], overlayIP: "10.77.0.2" } })
  await m.until((s) => s.frames.some((f) => f.type === "signal" && f.sessionId === sessionId))
  // The Mac answers; the phone learns its own relay ticket from that wg-resp, as a real phone does.
  m.send({ type: "signal", to: phone, from: mac, sessionId, payload: { kind: "wg-resp", publicKey: "k", endpoints: [], overlayIP: "10.77.0.1" } })
  await p.until((s) => s.frames.some((f) => f.type === "signal" && f.sessionId === sessionId && f.payload?.kind === "wg-resp"))
  const ticket = p.frames.filter((f) => f.type === "signal" && f.sessionId === sessionId).at(-1)?.relayTicket as string
  expect(typeof ticket).toBe("string")
  return { tok, phone, mac, sessionId, ticket, sockets: [p, m] as Sock[] }
}

const request = async (p: Awaited<ReturnType<typeof pair>>, method: string, path: string, body?: BodyInit, useHeaders = false, ticket: string | null = p.ticket) => {
  const query = useHeaders ? "" : `?sessionId=${p.sessionId}&deviceId=${p.phone}`
  const headers: Record<string, string> = { authorization: `Bearer ${p.tok}` }
  if (ticket !== null) headers["x-cmux-relay-ticket"] = ticket
  if (useHeaders) {
    headers["x-cmux-chunk-session"] = p.sessionId
    headers["x-cmux-chunk-device"] = p.phone
  }
  if (body && typeof body === "string") headers["content-type"] = "application/json"
  return worker.fetch(`https://api.test${path}${query}`, { method, headers, body })
}

describe("sealed chunk cache", () => {
  it("puts, gets, checks presence, batches, and is idempotent", async () => {
    const p = await pair()
    const one = id(1)
    const two = id(2)
    expect((await request(p, "PUT", `/v1/chunks/${one}`, bytes(3).buffer)).status).toBe(201)
    expect((await request(p, "PUT", `/v1/chunks/${one}`, bytes(3).buffer)).status).toBe(200)
    const got = await request(p, "GET", `/v1/chunks/${one}`)
    expect(got.status).toBe(200)
    expect([...new Uint8Array(await got.arrayBuffer())]).toEqual([7, 7, 7])
    const have = await request(p, "POST", "/v1/chunks/have", JSON.stringify({ ids: [one, two] }))
    expect(await have.json()).toEqual({ have: [true, false] })
    const batch = await request(p, "POST", "/v1/chunks/get", JSON.stringify({ ids: [two, one] }))
    const packed = new Uint8Array(await batch.arrayBuffer())
    expect(packed.byteLength).toBe(39)
    expect(Array.from(packed.slice(0, 32))).toEqual(Array.from(bytes(32, 1)))
    expect(new DataView(packed.buffer).getUint32(32)).toBe(3)
    expect([...packed.slice(36)]).toEqual([7, 7, 7])
    expect((await request(p, "GET", `/v1/chunks/${one}`, undefined, true)).status).toBe(200)
    p.sockets.forEach((s) => s.ws.close())
  })

  it("enforces syntax, size, pair isolation, and the cache cap", async () => {
    const p = await pair("chunk-isolation")
    expect((await request(p, "PUT", "/v1/chunks/ABC", bytes(1).buffer)).status).toBe(404)
    expect((await request(p, "PUT", `/v1/chunks/${id(3)}`, bytes(CHUNK_MAX_BYTES + 1).buffer)).status).toBe(413)
    const cacheNs = (env as any).CHUNK_CACHE
    const cache = cacheNs.get(cacheNs.idFromName(chunkPairName("chunk-isolation", "", p.phone, p.mac)))
    await (runInDurableObject as any)(cache, (_obj: any, state: any) => {
      state.storage.sql.exec(`INSERT OR REPLACE INTO chunks (id, data, size, created_at, last_read_at, expires_at) VALUES (?, ?, ?, ?, ?, ?)`, id(4), bytes(1).buffer, CHUNK_CACHE_BYTES, 1, 1, Date.now() + CHUNK_TTL_MS)
    })
    expect((await request(p, "PUT", `/v1/chunks/${id(5)}`, bytes(2).buffer)).status).toBe(201)
    expect((await request(p, "GET", `/v1/chunks/${id(4)}`)).status).toBe(404)
    expect((await request(p, "GET", `/v1/chunks/${id(5)}`)).status).toBe(200)
    const other = await pair("chunk-isolation")
    const otherSession = other.sessionId
    expect(otherSession).not.toBe(p.sessionId)
    const cross = await worker.fetch(`https://api.test/v1/chunks/${id(5)}?sessionId=${other.sessionId}&deviceId=${p.phone}`, { headers: { authorization: `Bearer ${p.tok}` } })
    expect(cross.status).toBe(403)
    // The phone's id needs the phone's own relay ticket: none, a wrong one, or another session's is refused.
    for (const ticket of [null, "", "not-a-ticket", other.ticket]) {
      expect((await request(p, "GET", `/v1/chunks/${id(5)}`, undefined, false, ticket)).status, `ticket ${ticket}`).toBe(403)
    }
    expect((await request(p, "GET", `/v1/chunks/${id(5)}`)).status).toBe(200)
    p.sockets.concat(other.sockets).forEach((s) => s.ws.close())
  })

  it("expires chunks through the Durable Object alarm", async () => {
    const p = await pair("chunk-ttl")
    const chunkId = id(6)
    expect((await request(p, "PUT", `/v1/chunks/${chunkId}`, bytes(1).buffer)).status).toBe(201)
    const cacheNs = (env as any).CHUNK_CACHE
    const cache = cacheNs.get(cacheNs.idFromName(chunkPairName("chunk-ttl", "", p.phone, p.mac)))
    await (runInDurableObject as any)(cache, (_obj: any, state: any) => state.storage.sql.exec(`UPDATE chunks SET expires_at = 1 WHERE id = ?`, chunkId))
    await runDurableObjectAlarm(cache)
    expect((await request(p, "GET", `/v1/chunks/${chunkId}`)).status).toBe(404)
    p.sockets.forEach((s) => s.ws.close())
  })

  it("measures a cached 4 MiB attachment in one batch against source upload", async () => {
    const p = await pair("chunk-measure")
    const payload = bytes(256 * 1024, 9).buffer
    const ids = Array.from({ length: 16 }, (_, n) => id(16 + n))
    const started = performance.now()
    for (const chunkId of ids) expect((await request(p, "PUT", `/v1/chunks/${chunkId}`, payload)).status).toBe(201)
    const uploadMs = performance.now() - started
    const cachedStart = performance.now()
    const cached = await request(p, "POST", "/v1/chunks/get", JSON.stringify({ ids }))
    expect((await cached.arrayBuffer()).byteLength).toBe(16 * (32 + 4 + payload.byteLength))
    const cachedMs = performance.now() - cachedStart
    const sourceStart = performance.now()
    for (const chunkId of ids.map((value) => `${value.slice(0, 62)}${value.endsWith("0") ? "01" : "00"}`)) expect((await request(p, "PUT", `/v1/chunks/${chunkId}`, payload)).status).toBe(201)
    const sourceMs = performance.now() - sourceStart
    console.log(JSON.stringify({ benchmark: "sealed-chunks-4MiB", localUploadMs: Math.round(uploadMs), localCachedBatchGetMs: Math.round(cachedMs), localSourceReuploadMs: Math.round(sourceMs), lteModelMs: { cachedBatchGet: Math.round(70 + (4 * 1024 * 1024 * 8 * 1000) / 12_000_000), sourceReupload: Math.round(16 * (70 + (256 * 1024 * 8 * 1000) / 12_000_000)) } }))
    p.sockets.forEach((s) => s.ws.close())
  }, 30_000)
})
