import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"

const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; FEED_DO: DurableObjectNamespace }
const worker = (exports as unknown as { default: Fetcher }).default

const sessionToken = async (stackUser: string) => {
  const key = await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256")
  return new SignJWT({ email: `${stackUser}@example.com`, name: stackUser })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(stackUser)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(key)
}

const call = async (path: string, token: string | undefined, body?: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, {
    method: body === undefined ? "GET" : "POST",
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
    ...(body === undefined ? {} : { body: JSON.stringify(body) })
  })
  return { status: res.status, json: (await res.json()) as any }
}
const op = (token: string, name: string, params: unknown, origin = "cli", key: string = crypto.randomUUID()) => call("/v1/ops", token, { op: name, params, idempotency_key: key, origin })
const read = (token: string, name: string, params: unknown = {}) => call("/v1/read", token, { op: name, params })

const b64u = (buf: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")

/** A signed-in user with one registered install and its access token. */
const setup = async (stackUser: string) => {
  const session = await sessionToken(stackUser)
  const user = (await op(session, "user.ensure", {})).json.value.id as string
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
  const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
  const reg = await op(session, "install.register", { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x!, y: jwk.y! }, kind: "mac", name: "mac", device_name: "mac", platform: "macos" })
  const install = reg.json.value.id as string
  const ch = await call("/v1/auth/challenge", undefined, { user, install })
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${ch.json.message_prefix}${ch.json.nonce}`))
  const tok = await call("/v1/auth/token", undefined, { user, install, nonce: ch.json.nonce, signature: b64u(sig) })
  return { session, user, install, token: tok.json.access_token as string }
}

const openFeed = async (token: string) => {
  const res = await worker.fetch("https://api.test/v1/wire/feed", { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": `cmux.wire.v1, bearer.${token}` } })
  expect(res.status).toBe(101)
  const ws = res.webSocket!
  const frames: Array<any> = []
  const waiters: Array<() => void> = []
  ws.addEventListener("message", (e) => {
    frames.push(JSON.parse(e.data as string))
    waiters.splice(0).forEach((w) => w())
  })
  ws.accept()
  const until = async (pred: (fs: Array<any>) => boolean) => {
    while (!pred(frames)) await new Promise<void>((r) => waiters.push(r))
  }
  return { ws, frames, until, send: (f: unknown) => ws.send(JSON.stringify(f)) }
}

interface FeedInternals {
  onWake(now: number): Promise<void>
}
const inFeed = (user: string, fn: (d: FeedInternals) => Promise<void>) =>
  (runInDurableObject as unknown as (stub: unknown, cb: (instance: unknown) => Promise<void>) => Promise<void>)(testEnv.FEED_DO.get(testEnv.FEED_DO.idFromName(user)), (i) => fn(i as FeedInternals))

const approve = { type: "request", kind: "approve", title: "Claude Code needs permission", prompt: { action: { type: "command", summary: "Build", command: "npm run build" }, scopes: ["once", "session"] }, poster: { agent: "term_1", harness: "claude-code", label: "Claude Code · api" } }

describe("feed end to end (workerd)", () => {
  it("posts over HTTP, echoes on the wire, takes one user answer, and replays by key", async () => {
    const s = await setup("feed-user-1")
    const wire = await openFeed(s.token)
    wire.send({ t: "subscribe", stream: `feed:${s.user}`, pending: [] })
    await wire.until((fs) => fs.some((f) => f.t === "snapshot"))

    const post = await op(s.token, "feed.post", approve, "cli", "post-1")
    expect(post.json).toMatchObject({ ok: true, stream: `feed:${s.user}`, value: { deduped: false, item: { kind: "approve", poster: { agent: "term_1", harness: "claude-code" } } } })
    const id = post.json.value.item.id as string
    expect((await op(s.token, "feed.post", approve, "cli", "post-1")).json).toMatchObject({ ok: true, replayed: true, transaction: post.json.transaction })
    await wire.until((fs) => fs.some((f) => f.t === "event" && f.op === "feed.post"))

    // An answer must come from a user action; the first answer wins.
    expect((await op(s.token, "feed.answer", { item: id, answer: { decision: "allow" } }, "cli")).json.error.code).toBe("auth.forbidden")
    const answer = await op(s.session, "feed.answer", { item: id, answer: { decision: "allow", scope: "session" } }, "user")
    expect(answer.json).toMatchObject({ ok: true, value: { item: { state: "answered" } } })
    await wire.until((fs) => fs.some((f) => f.t === "event" && f.op === "feed.answer"))
    const late = await op(s.token, "feed.answer", { item: id, answer: { decision: "deny" } }, "user")
    expect(late.json.error).toMatchObject({ code: "feed.closed" })

    const got = await read(s.token, "feed.get", { item: id })
    expect(got.json.value.item.answer.value).toEqual({ decision: "allow", scope: "session" })
    expect((await read(s.session, "feed.list", { state: "closed" })).json.value.items.map((i: any) => i.id)).toEqual([id])
    expect((await read(s.session, "feed.counts")).json.value).toMatchObject({ open_requests: 0 })
    const kinds = (await read(s.session, "feed.kinds")).json.value.kinds
    expect(kinds.map((k: any) => k.kind)).toContain("passkey")
    expect(kinds.find((k: any) => k.kind === "approve").answer_schema).toMatchObject({ type: "object", required: ["decision"] })
    wire.ws.close()
  })

  it("expires overdue requests and decides pushes from presence in the owner's wake", async () => {
    const s = await setup("feed-user-2")
    const short = await op(s.token, "feed.post", { ...approve, expires_in_ms: 10_000 })
    const pushed = await op(s.token, "feed.post", { ...approve, title: "second" })
    const quiet = await op(s.token, "feed.post", { ...approve, title: "third" })
    const [shortId, pushedId, quietId] = [short.json.value.item.id, pushed.json.value.item.id, quiet.json.value.item.id]
    expect(pushed.json.value.item.push_due_at).not.toBeNull()

    // No active Mac: the due push is sent.
    await inFeed(s.user, (d) => d.onWake(Date.now() + 30_000))
    expect((await read(s.token, "feed.get", { item: shortId })).json.value.item.state).toBe("expired")
    expect((await read(s.token, "feed.get", { item: pushedId })).json.value.item.pushed_at).not.toBeNull()

    // An active Mac on the wire: a re-armed high push is skipped (the user got the Mac banner).
    const wire = await openFeed(s.token)
    wire.send({ t: "presence.set", stream: `feed:${s.user}`, state: { active: true, client: "mac" } })
    wire.send({ t: "subscribe", stream: `feed:${s.user}`, pending: [] })
    await wire.until((fs) => fs.some((f) => f.t === "snapshot"))
    expect((await read(s.token, "feed.get", { item: quietId })).json.value.item.pushed_at).not.toBeNull()
    const fourth = await op(s.token, "feed.post", { ...approve, title: "fourth" })
    await inFeed(s.user, (d) => d.onWake(Date.now() + 30_000))
    const item = (await read(s.token, "feed.get", { item: fourth.json.value.item.id })).json.value.item
    expect(item).toMatchObject({ pushed_at: null, push_due_at: null })
    wire.ws.close()
  })

  it("refuses another user's feed items and internal ops over HTTP", async () => {
    const a = await setup("feed-user-3")
    const b = await setup("feed-user-4")
    const id = (await op(a.token, "feed.post", approve)).json.value.item.id
    expect((await read(b.token, "feed.get", { item: id })).status).toBe(400)
    const internal = await op(a.session, "feed.expire", { at: Date.now() })
    expect(internal.status).toBe(400)
  })
})
