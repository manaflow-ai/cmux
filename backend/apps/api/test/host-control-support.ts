import { env, exports } from "cloudflare:workers"
import { importJWK, SignJWT, type JWK } from "jose"

/**
 * Shared setup for the HostDO control-plane tests (b1-control-do.md): a signed-in user with a Mac
 * install that enrolled a host, an iPhone install, and sockets opened through the Worker route.
 * Frame waits resolve from the message listener (no polling).
 */

export const testEnv = env as unknown as Record<string, any> & { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string }
export const worker = (exports as unknown as { default: Fetcher }).default

export const call = async (path: string, token: string | undefined, body?: unknown, method = "POST") => {
  const res = await worker.fetch(`https://api.test${path}`, { method, headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) })
  return { status: res.status, json: (await res.json().catch(() => null)) as any }
}
const b64u = (buf: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")

export const stackToken = async (sub: string) =>
  new SignJWT({ email: `${sub}@example.com`, email_verified: true, name: sub })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))

export const op = (t: string, name: string, params: unknown) => call("/v1/ops", t, { op: name, params, idempotency_key: crypto.randomUUID(), origin: "cli" })

/** Registers an install of `kind` and returns its id and an access token. */
export const installToken = async (session: string, user: string, kind: string, platform: string) => {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
  const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
  const reg = await op(session, "install.register", { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x!, y: jwk.y! }, kind, name: kind, device_name: kind, platform })
  const install = reg.json.value.id as string
  const ch = await call("/v1/auth/challenge", undefined, { user, install })
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${ch.json.message_prefix}${ch.json.nonce}`))
  const token = (await call("/v1/auth/token", undefined, { user, install, nonce: ch.json.nonce, signature: b64u(sig) })).json.access_token as string
  return { install, token }
}

/** A user, their Mac install (which enrolled the host), their iPhone install. */
export const hostUser = async (tag: string) => {
  const sub = `${tag}-${crypto.randomUUID().slice(0, 8)}`
  const session = await stackToken(sub)
  const user = (await op(session, "user.ensure", {})).json.value.id as string
  const mac = await installToken(session, user, "cli", "macos")
  const enrolled = await op(mac.token, "host.enroll", { name: "mac", platform: "macos" })
  const host = enrolled.json.value.id as string
  const phone = await installToken(session, user, "ios", "ios")
  return { session, user, host, mac, phone }
}

export interface Socket {
  readonly status: number
  readonly ws: WebSocket
  readonly frames: Array<any>
  send(frame: unknown): void
  /** Resolves with the first frame (from `from` on) matching `pred`. */
  next(pred: (f: any) => boolean, from?: number): Promise<any>
  closed: Promise<number>
  hello(platform?: string, extra?: Record<string, unknown>): Promise<any>
}

export const openHost = async (host: string, token: string, query = ""): Promise<Socket & { body?: string }> => {
  const res = await worker.fetch(`https://api.test/v1/wire/host/${host}${query}`, { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": `cmux.wire.v1, bearer.${token}` } })
  const ws = res.webSocket as WebSocket
  const frames: Array<any> = []
  const waiters: Array<{ pred: (f: any) => boolean; from: number; resolve: (f: any) => void }> = []
  let onClose: (code: number) => void = () => {}
  const closed = new Promise<number>((r) => (onClose = r))
  const s: Socket & { body?: string } = {
    status: res.status,
    ws,
    frames,
    send: (f) => ws.send(typeof f === "string" ? f : JSON.stringify(f)),
    next: (pred, from = 0) => {
      const hit = frames.slice(from).find(pred)
      return hit ? Promise.resolve(hit) : new Promise((resolve) => waiters.push({ pred, from, resolve }))
    },
    closed,
    hello: async (platform = "ios", extra = {}) => {
      const at = frames.length
      s.send({ t: "hello", proto: "cmux.mobile/1", min: 1, max: 1, caps: ["read", "signal", "presence", "resume", "x-unknown"], client: { install: "in_self", platform, app_version: "1.0.0" }, ...extra })
      return s.next((f) => f.t === "hello.ok" || f.t === "error", at)
    }
  }
  if (!ws) {
    s.body = await res.text()
    return s
  }
  ws.addEventListener("message", (e) => {
    const f = JSON.parse(e.data as string)
    frames.push(f)
    const idx = frames.length - 1
    for (const w of [...waiters]) if (idx >= w.from && w.pred(f)) [waiters.splice(waiters.indexOf(w), 1), w.resolve(f)]
  })
  ws.addEventListener("close", (e) => onClose(e.code))
  ws.accept()
  return s
}

/** Resolves after every frame already sent has been handled by the object (a round trip through it). */
export const roundTrip = async (s: Socket) => {
  const at = s.frames.length
  const t = `rt.${crypto.randomUUID().slice(0, 8)}`
  s.send({ t })
  await s.next((f) => f.t === "error" && typeof f.message === "string" && f.message.includes(t), at)
}
