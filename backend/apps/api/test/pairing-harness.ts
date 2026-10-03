/** Shared workerd helpers for the server pairing tests (sessions, API calls, a server that begins pairing, the wait socket). */
import { env, exports } from "cloudflare:workers"
import { runDurableObjectAlarm, runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { beginProofMessage } from "../src/domains/pairing.ts"

export const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; ENVIRONMENT: string; TEAM_DO: DurableObjectNamespace; USER_DO: DurableObjectNamespace; PAIRING_DO: DurableObjectNamespace }
export const inDO = runInDurableObject as unknown as (stub: unknown, cb: (instance: any) => Promise<void>) => Promise<void>
export const runAlarm = runDurableObjectAlarm as unknown as (stub: unknown) => Promise<boolean>
export const worker = (exports as unknown as { default: Fetcher }).default

export const sessionToken = async (stackUser: string) => {
  const key = await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256")
  return new SignJWT({ email: `${stackUser}@example.com`, email_verified: true, name: stackUser })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(stackUser)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(key)
}

export const call = async (path: string, token: string | undefined, body?: unknown, extra: Record<string, string> = {}) => {
  const res = await worker.fetch(`https://api.test${path}`, {
    method: body === undefined ? "GET" : "POST",
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}), ...extra },
    ...(body === undefined ? {} : { body: JSON.stringify(body) })
  })
  return { status: res.status, json: (await res.json()) as any }
}
export const op = (token: string, name: string, params: unknown, key = crypto.randomUUID()) => call("/v1/ops", token, { op: name, params, idempotency_key: key, origin: "user" })
export const read = (token: string, name: string, params: unknown) => call("/v1/read", token, { op: name, params })
export const b64u = (buf: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")

/** What a fresh `cmux server up` does: make an install key and a WireGuard key, prove possession, begin. */
export const beginPairing = async (issuedAt = Date.now(), forge = false, ip?: string, key?: CryptoKeyPair) => {
  const pair = key ?? ((await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair)
  const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
  const public_jwk = { kty: "EC", crv: "P-256", x: jwk.x!, y: jwk.y! }
  const wg = btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32))))
  const thumb = b64u(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`{"crv":"P-256","kty":"EC","x":"${jwk.x}","y":"${jwk.y}"}`)))
  const signer = forge ? ((await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair).privateKey : pair.privateKey
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, signer, new TextEncoder().encode(beginProofMessage(testEnv.ENVIRONMENT, thumb, wg, issuedAt)))
  const info = { name: "Studio", platform: "linux", os_version: "Ubuntu 24.04", arch: "x86_64", cmux_version: "0.1.0" }
  const res = await call("/v1/pair/begin", undefined, { public_jwk, wg_public_key: wg, info, issued_at: issuedAt, signature: b64u(sig) }, ip ? { "cf-connecting-ip": ip } : {})
  return { res, pair, public_jwk, wg, thumb }
}

export const waitFor = async (code: string, secret: string) => {
  const res = await worker.fetch(`https://api.test/v1/pair/wait?code=${code}`, { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": `cmux.pair.v1, collect.${secret}` } })
  const ws = res.webSocket
  const frames: Array<any> = []
  const closes: Array<number> = []
  let wake: (() => void) | null = null
  ws?.addEventListener("message", (e) => {
    frames.push(JSON.parse(e.data as string))
    wake?.()
  })
  ws?.addEventListener("close", (e) => {
    closes.push(e.code)
    wake?.()
  })
  ws?.accept()
  const until = async (pred: () => boolean) => {
    while (!pred()) await new Promise<void>((r) => (wake = r))
  }
  return { status: res.status, frames, closes, until }
}

/** A signed-in session principal, as http.ts builds it, for calling pairApprove directly. */
export const sessionPrincipal = (user: string, team: string) => ({ kind: "session" as const, identity: `session:${user}`, user, team })

/** pairApprove's submit, straight to the real UserDO (what http.ts does for cloud:UserDO). */
export const userSubmit = async (_owner: string, p: { user: string }, f: { op: string; params: unknown; idempotency_key: string; origin: string }) =>
  (testEnv.USER_DO.get(testEnv.USER_DO.idFromName(p.user)) as any).submit(p.user, p, { t: "op", ...f })
