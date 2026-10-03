import { env, exports } from "cloudflare:workers"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { CLOUDFLARE_STUN, handleIceServers } from "../src/rtc-ice.ts"
import type { Env } from "../src/env.ts"

const testEnv = env as unknown as Env & { STACK_TEST_PRIVATE_JWK: string }
const worker = (exports as unknown as { default: Fetcher }).default

const sessionToken = async (stackUser: string) => {
  const key = await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256")
  return new SignJWT({ email: `${stackUser}@example.com`, email_verified: true })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(stackUser)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(key)
}

interface Socket {
  readonly ws: WebSocket
  send(frame: Record<string, unknown>): void
  /** Next `rtc.*` frame (the welcome and other ledger frames are skipped); no polling. */
  next(): Promise<Record<string, any>>
  closed: Promise<number>
}

const connect = async (token: string): Promise<Socket> => {
  const res = await worker.fetch("https://api.test/v1/wire/user", { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": `cmux.wire.v1, bearer.${token}` } })
  expect(res.status).toBe(101)
  const ws = res.webSocket!
  const queue: Array<Record<string, any>> = []
  const waiters: Array<(f: Record<string, any>) => void> = []
  let onClose: (code: number) => void = () => {}
  const closed = new Promise<number>((r) => (onClose = r))
  ws.addEventListener("message", (e) => {
    const frame = JSON.parse(e.data as string) as Record<string, any>
    if (typeof frame.t !== "string" || !frame.t.startsWith("rtc.")) return
    const w = waiters.shift()
    if (w) w(frame)
    else queue.push(frame)
  })
  ws.addEventListener("close", (e) => onClose(e.code))
  ws.accept()
  return {
    ws,
    closed,
    send: (frame) => ws.send(JSON.stringify(frame)),
    next: () => (queue.length > 0 ? Promise.resolve(queue.shift()!) : new Promise((r) => waiters.push(r)))
  }
}

const hello = async (s: Socket, role: "host" | "client", peer: string, extra: Record<string, unknown> = {}) => {
  s.send({ t: "rtc.hello", role, peer, ...extra })
  expect(await s.next()).toEqual({ t: "rtc.welcome", peer })
}

describe("rtc signaling on /v1/wire/user", { timeout: 30_000 }, () => {
  it("lists online hosts, relays offer/answer/candidates with a stamped sender, and drops a host that leaves", async () => {
    const token = await sessionToken("rtc-user-1")
    const mac = await connect(token)
    await hello(mac, "host", "host-mac-0001", { name: "Studio", tag: "rtcdev", platform: "macos", app_version: "0.1" })
    const phone = await connect(token)
    phone.send({ t: "rtc.hello", role: "client", peer: "phone-0001" })
    expect(await phone.next()).toEqual({ t: "rtc.welcome", peer: "phone-0001" })
    const listed = await phone.next()
    expect(listed.t).toBe("rtc.hosts")
    expect(listed.hosts).toHaveLength(1)
    expect(listed.hosts[0]).toMatchObject({ peer: "host-mac-0001", name: "Studio", tag: "rtcdev", platform: "macos", app_version: "0.1" })

    // The sender claims to be someone else; the relay stamps the real peer.
    phone.send({ t: "rtc.signal", to: "host-mac-0001", session: "sess-00000001", kind: "offer", sdp: "v=0 offer", from: "spoofed" })
    expect(await mac.next()).toEqual({ t: "rtc.signal", from: "phone-0001", from_role: "client", session: "sess-00000001", kind: "offer", sdp: "v=0 offer" })
    mac.send({ t: "rtc.signal", to: "phone-0001", session: "sess-00000001", kind: "answer", sdp: "v=0 answer" })
    expect(await phone.next()).toMatchObject({ from: "host-mac-0001", from_role: "host", kind: "answer", sdp: "v=0 answer" })
    phone.send({ t: "rtc.signal", to: "host-mac-0001", session: "sess-00000001", kind: "candidate", candidate: "candidate:1 1 udp 1 1.2.3.4 5 typ host", sdp_mid: "0", sdp_mline_index: 0 })
    expect(await mac.next()).toMatchObject({ kind: "candidate", sdp_mid: "0", sdp_mline_index: 0 })

    mac.ws.close(1000, "bye")
    expect(await phone.next()).toEqual({ t: "rtc.hosts", hosts: [] })
    phone.send({ t: "rtc.signal", to: "host-mac-0001", session: "sess-00000002", kind: "offer", sdp: "x" })
    expect(await phone.next()).toEqual({ t: "rtc.error", code: "rtc.peer_offline", session: "sess-00000002", to: "host-mac-0001" })
  })

  it("never crosses users, refuses same-role signaling and frames before hello, and replaces a reconnecting peer", async () => {
    const alice = await sessionToken("rtc-user-alice")
    const mallory = await sessionToken("rtc-user-mallory")
    const mac = await connect(alice)
    await hello(mac, "host", "host-alice-001")
    const intruder = await connect(mallory)
    intruder.send({ t: "rtc.signal", to: "host-alice-001", session: "sess-00000003", kind: "offer", sdp: "x" })
    expect(await intruder.next()).toEqual({ t: "rtc.error", code: "rtc.no_hello" })
    await hello(intruder, "client", "phone-mallory1")
    expect(await intruder.next()).toEqual({ t: "rtc.hosts", hosts: [] })
    intruder.send({ t: "rtc.signal", to: "host-alice-001", session: "sess-00000003", kind: "offer", sdp: "x" })
    expect((await intruder.next()).code).toBe("rtc.peer_offline")

    const otherMac = await connect(alice)
    await hello(otherMac, "host", "host-alice-002")
    mac.send({ t: "rtc.signal", to: "host-alice-002", session: "sess-00000004", kind: "offer", sdp: "x" })
    expect((await mac.next()).code).toBe("rtc.peer_offline")

    const again = await connect(alice)
    await hello(again, "host", "host-alice-001")
    expect(await mac.closed).toBe(4000)
  })

  it("validates frames", async () => {
    const s = await connect(await sessionToken("rtc-user-2"))
    s.send({ t: "rtc.hello", role: "admin", peer: "p" })
    expect((await s.next()).code).toBe("validation.invalid")
    await hello(s, "client", "phone-0002")
    await s.next() // host list
    s.send({ t: "rtc.signal", to: "host-x-00000", session: "sess-00000005", kind: "exec", sdp: "x" })
    expect((await s.next()).code).toBe("validation.invalid")
    s.send({ t: "rtc.signal", to: "host-x-00000", session: "sess-00000005", kind: "offer", sdp: "x".repeat(70_000) })
    expect((await s.next()).code).toBe("rtc.too_large")
  })
})

describe("GET /v1/rtc/ice-servers", () => {
  it("needs a bearer and answers STUN only when TURN is not configured", async () => {
    expect((await worker.fetch("https://api.test/v1/rtc/ice-servers")).status).toBe(401)
    const res = await worker.fetch("https://api.test/v1/rtc/ice-servers", { headers: { Authorization: `Bearer ${await sessionToken("rtc-user-3")}` } })
    expect(res.status).toBe(200)
    expect(await res.json()).toEqual({ ice_servers: [{ urls: [CLOUDFLARE_STUN] }], ttl: 43200, turn: false })
  })

  it("mints Cloudflare TURN credentials and drops port 53 URLs", async () => {
    const calls: Array<{ url: string; auth: string | null; body: string }> = []
    const fake = (async (url: string, init: RequestInit) => {
      calls.push({ url, auth: new Headers(init.headers).get("Authorization"), body: String(init.body) })
      return new Response(
        JSON.stringify({
          iceServers: [
            { urls: ["stun:stun.cloudflare.com:3478", "stun:stun.cloudflare.com:53"] },
            { urls: ["turn:turn.cloudflare.com:3478?transport=udp", "turn:turn.cloudflare.com:53?transport=udp", "turns:turn.cloudflare.com:443?transport=tcp"], username: "u", credential: "c" }
          ]
        }),
        { status: 201 }
      )
    }) as unknown as typeof fetch
    const request = new Request("https://api.test/v1/rtc/ice-servers", { headers: { Authorization: `Bearer ${await sessionToken("rtc-user-4")}` } })
    const res = await handleIceServers(request, { ...testEnv, CF_TURN_KEY_ID: "key-1", CF_TURN_API_TOKEN: "secret" }, fake)
    expect(calls).toEqual([{ url: "https://rtc.live.cloudflare.com/v1/turn/keys/key-1/credentials/generate-ice-servers", auth: "Bearer secret", body: JSON.stringify({ ttl: 43200 }) }])
    expect(await res.json()).toEqual({
      ice_servers: [
        { urls: ["stun:stun.cloudflare.com:3478"] },
        { urls: ["turn:turn.cloudflare.com:3478?transport=udp", "turns:turn.cloudflare.com:443?transport=tcp"], username: "u", credential: "c" }
      ],
      ttl: 43200,
      turn: true
    })
  })

  it("falls back to STUN when Cloudflare refuses", async () => {
    const fake = (async () => new Response("no", { status: 500 })) as unknown as typeof fetch
    const request = new Request("https://api.test/v1/rtc/ice-servers", { headers: { Authorization: `Bearer ${await sessionToken("rtc-user-5")}` } })
    const res = await handleIceServers(request, { ...testEnv, CF_TURN_KEY_ID: "key-1", CF_TURN_API_TOKEN: "secret" }, fake)
    expect(await res.json()).toMatchObject({ turn: false, turn_error: "unavailable" })
  })
})
