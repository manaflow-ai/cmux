import { env, exports } from "cloudflare:workers"
import { importJWK, SignJWT, type JWK } from "jose"
import catalog from "../../../../catalog/cloud-operations.json"

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

// ---- sample params from the operation catalog
type Type = any
const types = (catalog as any).types as Record<string, Type>
export const catalogOps = (catalog as any).operations as Record<string, { class: "read" | "mutation"; principals: Array<string>; owner: string; params: { fields: Record<string, { required: boolean; type: Type }> } }>
const CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
const LOWER = "abcdefghijklmnopqrstuvwxyz0123456789"
const fromClass = (cls: string): string => {
  if (cls.includes("0-9A-HJKMNP-TV-Z")) return CROCKFORD
  if (cls.includes("0-9a-hjkmnp-tv-z")) return CROCKFORD.toLowerCase()
  if (cls.includes("a-z0-9")) return LOWER
  if (cls.includes("0-9a-f")) return "0123456789abcdef"
  return "abcdefghijklmnopqrstuvwxyz0123456789_"
}
const rnd = (alphabet: string, n: number) => Array.from({ length: n }, () => alphabet[Math.floor(Math.random() * alphabet.length)]).join("")
/** A string that matches the simple `^literal[class]{n}$` patterns the id types use; undefined for a pattern it cannot build. */
export const fromPattern = (pattern: string): string | undefined => {
  const m = /^\^([A-Za-z_]*)\((?:dm_)?\)\?|^\^([A-Za-z_]*)(?:\[([^\]]+)\]\{(\d+)(?:,(\d+))?\})\$$/.exec(pattern)
  const simple = /^\^([A-Za-z_]*)\[([^\]]+)\]\{(\d+)(?:,(\d+))?\}\$$/.exec(pattern)
  if (simple) return simple[1] + rnd(fromClass(simple[2]!), Number(simple[3]))
  const conv = /^\^conv_\(dm_\)\?\[0-9A-HJKMNP-TV-Z\]\{26\}\$$/.exec(pattern)
  if (conv) return `conv_${rnd(CROCKFORD, 26)}`
  void m
  return undefined
}
const stringFor = (t: Type): string => {
  if (t.pattern) {
    const s = fromPattern(t.pattern)
    if (s !== undefined) return s
    if (t.pattern.includes("@")) return "x@tenant.test"
  }
  const min = t.min_length ?? 1
  return "x".repeat(Math.max(min, 1))
}
/** Sample a value of a catalog type. `ids` maps a ref name (MachineId ...) to a real id. */
export const sample = (t: Type, ids: Record<string, string>, depth = 0): unknown => {
  if (depth > 6) return null
  switch (t.kind) {
    case "ref": {
      if (ids[t.name]) return ids[t.name]
      if (t.name === "ParticipantId") return `user_${rnd(LOWER, 20)}`
      const def = types[t.name]
      return def ? sample(def, ids, depth + 1) : "x"
    }
    case "primitive":
      switch (t.name) {
        case "string":
          return stringFor(t)
        case "boolean":
          return false
        case "int64":
        case "int32":
        case "int":
        case "number":
        case "float64":
          return Math.max(t.minimum ?? 0, 1)
        case "decimal":
          return "1"
        default:
          return stringFor(t)
      }
    case "enum":
      return t.values?.[0]?.value ?? t.values?.[0] ?? t.variants?.[0]
    case "array":
      return (t.min_length ?? t.min_items) ? [sample(t.items, ids, depth + 1)] : []
    case "nullable":
      return null
    case "union":
      return sample((t.variants ?? t.members ?? t.options)[0], ids, depth + 1)
    case "object": {
      const out: Record<string, unknown> = {}
      for (const [k, f] of Object.entries<any>(t.fields ?? {})) if (f.required) out[k] = sample(f.type, ids, depth + 1)
      return out
    }
    case "map":
      return {}
    default:
      return null
  }
}
export const sampleParams = (op: string, ids: Record<string, string>) => {
  const out: Record<string, unknown> = {}
  for (const [k, f] of Object.entries(catalogOps[op]!.params.fields)) if (f.required) out[k] = sample(f.type, ids)
  return out
}
/** Every id-shaped string in a JSON value, keyed by the catalog id type whose pattern it matches. */
export const idsIn = (value: unknown): Record<string, string> => {
  const found: Record<string, string> = {}
  const patterns = Object.entries(types).filter(([name, t]) => name.endsWith("Id") && t.kind === "primitive" && t.pattern).map(([name, t]) => [name, new RegExp(t.pattern)] as const)
  const walk = (v: unknown) => {
    if (typeof v === "string") {
      for (const [name, re] of patterns) if (!found[name] && re.test(v)) found[name] = v
    } else if (Array.isArray(v)) v.forEach(walk)
    else if (v && typeof v === "object") Object.values(v).forEach(walk)
  }
  walk(value)
  return found
}
/** Drop keys that change on every read (times, sequences, revisions) so two reads of an unchanged tenant compare equal. */
export const stable = (v: unknown): unknown => {
  if (Array.isArray(v)) return v.map(stable)
  if (v && typeof v === "object") return Object.fromEntries(Object.entries(v).filter(([k]) => !/(_at|^at|_ms|seq|revision|version|rev|cursor|stream|transaction|nonce)$/i.test(k)).map(([k, x]) => [k, stable(x)]))
  return v
}

/** Replace every id-shaped string and every long random-looking run so two replies about different ids compare equal in shape. */
export const shape = (raw: string): string =>
  raw
    .replace(/\b(user|team|vm|snap|conv|dev|inst|host|grp|auto|conn|run|fi|agent|grant|inv|msg|ws|trg|enr|lease|addr)_[0-9A-Za-z]{8,64}\b/g, "$1_<ID>")
    .replace(/"(transaction|idempotency_key|nonce)":"[^"]*"/g, '"$1":"<X>"')
    .replace(/\b\d{12,14}\b/g, "<T>")
    .replace(/"(revision|sequence|seq|n)":"?\d+"?/g, '"$1":<N>')
