import { env, exports } from "cloudflare:workers"
import { importJWK, SignJWT, type JWK } from "jose"
import { sampleParams, catalogOps } from "./tenant-sample.ts"

/**
 * Tenant-isolation test kit (plans/cmux-next/tenant-isolation-DESIGN.md): throwaway accounts that call the
 * public routes with their own fake Stack session or install token, op params generated from the checked-in
 * operation catalog, and a canary scan that fails when one tenant's marker shows up in another tenant's reply.
 * Fake keys and fake identities only; no real user data and no network.
 */
const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string }
export const worker = (exports as unknown as { default: Fetcher }).default

export interface Reply {
  readonly status: number
  readonly body: any
  /** error.code, or undefined when the call succeeded. */
  readonly code: string | undefined
  readonly raw: string
}
const send = async (path: string, token: string | undefined, body: unknown, headers: Record<string, string> = {}): Promise<Reply> => {
  const res = await worker.fetch(`https://api.test${path}`, { method: "POST", headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}), ...headers }, body: JSON.stringify(body) })
  const raw = await res.text()
  let parsed: any = null
  try {
    parsed = JSON.parse(raw)
  } catch {}
  return { status: res.status, body: parsed, code: parsed?.error?.code, raw }
}
export const post = send
export const callOp = (token: string | undefined, op: string, params: unknown, key: string = crypto.randomUUID()) => send("/v1/ops", token, { op, params, idempotency_key: key, origin: "user" })
export const callRead = (token: string | undefined, op: string, params: unknown) => send("/v1/read", token, { op, params })
export const call = (cls: string, token: string | undefined, op: string, params: unknown) => (cls === "read" ? callRead(token, op, params) : callOp(token, op, params))
/** A call succeeded: HTTP 200 and no error object (the API answers `ok: true`, or a value without `ok`). */
export const succeeded = (r: Reply) => r.status === 200 && r.code === undefined && r.body?.ok !== false

const b64u = (b: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
export const stackSession = async (sub: string, email: string, name: string, extra: Record<string, unknown> = {}, ttl = "10m") =>
  new SignJWT({ email, email_verified: true, name, ...extra })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime(ttl)
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))

export interface Tenant {
  /** The tag (a, b, c ...) and the canary that every string this tenant creates carries. */
  readonly tag: string
  readonly canary: string
  readonly email: string
  readonly name: string
  readonly sub: string
  readonly session: string
  readonly user: string
  readonly team: string
  /** An install token (kind cli) of this tenant, and its install id. */
  readonly installToken: string
  readonly install: string
  readonly keyPair: CryptoKeyPair
}

/** A throwaway tenant: Stack subject `e2e-tenant-<tag>` (on the test CLOUD_ALLOWED_TEAMS list), one cli install and its token. */
export const makeTenant = async (tag: string, kind = "cli"): Promise<Tenant> => {
  const sub = `e2e-tenant-${tag}`
  const canary = `CANARY-${tag.toUpperCase()}-${crypto.randomUUID().slice(0, 8)}`
  const email = `${sub}@tenant.test`
  const name = `${canary} Name`
  const session = await stackSession(sub, email, name)
  const ensured = await callOp(session, "user.ensure", {})
  if (!succeeded(ensured)) throw new Error(`user.ensure ${tag}: ${ensured.raw}`)
  const user = ensured.body.value.id as string
  const keyPair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
  const jwk = (await crypto.subtle.exportKey("jwk", keyPair.publicKey)) as JsonWebKey
  const reg = await callOp(session, "install.register", { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x!, y: jwk.y! }, kind, name: `${canary} install`, device_name: `${canary} device`, platform: "macos" })
  if (!succeeded(reg)) throw new Error(`install.register ${tag}: ${reg.raw}`)
  const install = reg.body.value.id as string
  const installToken = await mintInstallToken({ user, install, keyPair })
  if (!installToken) throw new Error(`install token ${tag}`)
  return { tag, canary, email, name, sub, session, user, team: ensured.body.value.personal_team as string, installToken, install, keyPair }
}
export const mintInstallToken = async (i: { user: string; install: string; keyPair: CryptoKeyPair }): Promise<string | undefined> => {
  const ch = await send("/v1/auth/challenge", undefined, { user: i.user, install: i.install })
  if (ch.status !== 200) return undefined
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, i.keyPair.privateKey, new TextEncoder().encode(`${ch.body.message_prefix}${ch.body.nonce}`))
  const tok = await send("/v1/auth/token", undefined, { user: i.user, install: i.install, nonce: ch.body.nonce, signature: b64u(sig) })
  return tok.status === 200 ? (tok.body.access_token as string) : undefined
}

export * from "./tenant-sample.ts"
