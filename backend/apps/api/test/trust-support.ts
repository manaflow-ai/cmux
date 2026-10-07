import { linkCertMessage, type LinkPurpose } from "../src/domains/link-cert.ts"
import { call, op, stackToken, testEnv, worker, type Socket } from "./host-control-support.ts"

/**
 * Shared setup for the B6 pairing tests (plans/cmux-next/ios-next/b6-pairing.md): users with a Mac
 * install that enrolled a host and an iPhone install, both keeping their install key so they can
 * sign link certs, and `/v1/wire/user` sockets. Frame waits resolve from listeners (no polling).
 */

export const b64u = (buf: ArrayBuffer | Uint8Array) => btoa(String.fromCharCode(...new Uint8Array(buf instanceof Uint8Array ? buf : new Uint8Array(buf)))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")

export interface Device {
  readonly install: string
  readonly token: string
  readonly key: CryptoKeyPair
}

export const device = async (session: string, user: string, kind: string, platform: string): Promise<Device> => {
  const key = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
  const jwk = (await crypto.subtle.exportKey("jwk", key.publicKey)) as JsonWebKey
  const reg = await op(session, "install.register", { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x!, y: jwk.y! }, kind, name: `${kind}-${user.slice(-4)}`, device_name: kind, platform })
  const install = reg.json.value.id as string
  const ch = await call("/v1/auth/challenge", undefined, { user, install })
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key.privateKey, new TextEncoder().encode(`${ch.json.message_prefix}${ch.json.nonce}`))
  const token = (await call("/v1/auth/token", undefined, { user, install, nonce: ch.json.nonce, signature: b64u(sig) })).json.access_token as string
  return { install, token, key }
}

export interface Account {
  readonly session: string
  readonly user: string
  readonly team: string
  readonly host: string
  readonly mac: Device
  readonly phone: Device
}

export const account = async (tag: string): Promise<Account> => {
  const sub = `${tag}-${crypto.randomUUID().slice(0, 8)}`
  const session = await stackToken(sub)
  const ensured = (await op(session, "user.ensure", {})).json.value
  const user = ensured.id as string
  const mac = await device(session, user, "mac", "macos")
  const enrolled = await op(mac.token, "host.enroll", { name: `Studio ${tag}`, platform: "macos" })
  const phone = await device(session, user, "ios", "ios")
  return { session, user, team: ensured.personal_team as string, host: enrolled.json.value.id as string, mac, phone }
}

export const randomKey = () => b64u(crypto.getRandomValues(new Uint8Array(32)))

/** A link cert signed by `signer` (default: the device's own install key). */
export const cert = async (user: string, d: Device, opts: { purpose?: LinkPurpose; key?: string; issued_at?: number; lifetime?: number; signer?: CryptoKey; environment?: string } = {}) => {
  const issued_at = opts.issued_at ?? Date.now()
  const body = { purpose: opts.purpose ?? "direct", user, install: d.install, key: opts.key ?? randomKey(), issued_at, expires_at: issued_at + (opts.lifetime ?? 30 * 86_400_000) }
  const message = linkCertMessage(opts.environment ?? testEnv.ENVIRONMENT, body)
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, opts.signer ?? d.key.privateKey, new TextEncoder().encode(message))
  return { ...body, signature: b64u(sig) }
}

export const openUser = async (token: string): Promise<Socket> => {
  const res = await worker.fetch("https://api.test/v1/wire/user", { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": `cmux.wire.v1, bearer.${token}` } })
  const ws = res.webSocket as WebSocket
  const frames: Array<any> = []
  const waiters: Array<{ pred: (f: any) => boolean; from: number; resolve: (f: any) => void }> = []
  let onClose: (code: number) => void = () => {}
  const closed = new Promise<number>((r) => (onClose = r))
  const s: Socket = {
    status: res.status,
    ws,
    frames,
    send: (f) => ws.send(typeof f === "string" ? f : JSON.stringify(f)),
    next: (pred, from = 0) => {
      const hit = frames.slice(from).find(pred)
      return hit ? Promise.resolve(hit) : new Promise((resolve) => waiters.push({ pred, from, resolve }))
    },
    closed,
    hello: async () => ({})
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

/** Sends one op and resolves with its result or reject. */
export const send = async (s: Socket, name: string, params: unknown, key = crypto.randomUUID()) => {
  const at = s.frames.length
  s.send({ t: "op", op: name, params, idempotency_key: key, origin: "user" })
  return s.next((f) => (f.t === "result" || f.t === "reject") && f.idempotency_key === key, at)
}

/** Subscribes `trust:<user>` and resolves with the snapshot state. */
export const subscribeTrust = async (s: Socket, user: string) => {
  const at = s.frames.length
  s.send({ t: "subscribe", stream: `trust:${user}` })
  return (await s.next((f) => (f.t === "snapshot" && f.stream === `trust:${user}`) || f.t === "error", at)) as any
}

/** Publishes `d`'s direct cert (with `host` for a Mac). */
export const publish = async (s: Socket, user: string, d: Device, host?: string, opts: Parameters<typeof cert>[2] = {}) => {
  const c = await cert(user, d, opts)
  return { cert: c, reply: await send(s, "trust.key.publish", { cert: c, ...(host ? { host } : {}) }) }
}

/** The Mac makes an offer; returns the parsed QR link fields. */
export const offer = async (s: Socket, a: Account) => {
  const r = await send(s, "pairing.offer", { host: a.host, team: a.team })
  if (r.t !== "result") return { reply: r }
  const url = new URL((r.value.link as string).replace("cmux://", "https://cmux.invalid/"))
  return { reply: r, code: url.searchParams.get("o")!, key: url.searchParams.get("k")!, url }
}
