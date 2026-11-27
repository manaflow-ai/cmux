import { createLocalJWKSet, decodeJwt, decodeProtectedHeader, jwtVerify, type JWK, type JWTPayload, type JWTVerifyGetKey } from "jose"
import type { Env } from "./env.ts"

const STACK_API = "https://api.stack-auth.com"

/** One Stack project whose users the Worker accepts (an entry of STACK_PROJECTS). */
export interface StackProject {
  readonly id: string
  /** "dev" or "prod"; for logs only. */
  readonly label: string
  /** Sent on client-API calls when non-empty (production needs none). */
  readonly publishableClientKey: string
  /** Where a team invitation email links to (a trusted domain of this project). */
  readonly inviteCallbackUrl: string
}

const parsed = new Map<string, ReadonlyArray<StackProject>>()
/** The configured projects, primary first. Throws on a malformed config (a deploy error, not a caller error). */
export const stackProjects = (env: Env): ReadonlyArray<StackProject> => {
  let list = parsed.get(env.STACK_PROJECTS)
  if (!list) {
    const raw = JSON.parse(env.STACK_PROJECTS) as Array<Partial<StackProject>>
    if (!Array.isArray(raw) || raw.length === 0) throw new Error("STACK_PROJECTS must be a non-empty array")
    list = raw.map((p) => {
      if (typeof p.id !== "string" || !p.id) throw new Error("STACK_PROJECTS entry without id")
      return { id: p.id, label: p.label ?? p.id, publishableClientKey: p.publishableClientKey ?? "", inviteCallbackUrl: p.inviteCallbackUrl ?? "" }
    })
    parsed.set(env.STACK_PROJECTS, list)
  }
  return list
}

export const primaryProject = (env: Env): StackProject => stackProjects(env)[0]!
export const projectById = (env: Env, id: string): StackProject | undefined => stackProjects(env).find((p) => p.id === id)

export interface Caller {
  /** The verified JWT `sub`. Unique within its project; pair it with `projectId` wherever identity matters. */
  readonly userId: string
  /** The Stack project that issued the token (one of STACK_PROJECTS). */
  readonly projectId: string
  /** The raw Stack access token, used for client-API membership checks when no server key exists. */
  readonly token: string
}

const issuerOf = (projectId: string) => `${STACK_API}/api/v1/projects/${projectId}`

/** A project's signing keys, and a way to refetch them now (an unknown `kid`, a failed fetch). */
export interface KeySet {
  readonly get: JWTVerifyGetKey
  readonly reload?: () => Promise<void>
}

const keySets = new Map<string, KeySet>()
/** How long a project's keys are reused (they rotate rarely; an unknown `kid` refetches at once). */
const JWKS_MAX_AGE_S = 600

/**
 * A project's keys, shared by every isolate in the colo through the Cache API: Server-Timing showed a
 * fresh isolate (most WebSocket upgrades land on one) paying 110-150 ms to fetch them from Stack before
 * it could verify a token. The isolate keeps its own copy too; `reload` (unknown `kid`, failed fetch)
 * goes to Stack and refreshes the shared copy.
 */
const sharedJwks = (projectId: string): KeySet => {
  const url = `${issuerOf(projectId)}/.well-known/jwks.json`
  let local: { at: number; get: JWTVerifyGetKey } | undefined
  const cache = (): Cache | undefined => (typeof caches !== "undefined" ? (caches as unknown as { default: Cache }).default : undefined)
  const fromStack = async (): Promise<{ keys: Array<JWK> }> => {
    const res = await fetch(url, { signal: AbortSignal.timeout(5_000) })
    if (!res.ok) throw Object.assign(new Error(`jwks ${res.status}`), { code: "ERR_JWKS_INVALID" })
    const body = (await res.json()) as { keys: Array<JWK> }
    await cache()
      ?.put(url, new Response(JSON.stringify(body), { headers: { "content-type": "application/json", "cache-control": `max-age=${JWKS_MAX_AGE_S}` } }))
      .catch(() => {})
    return body
  }
  const load = async (fresh: boolean): Promise<JWTVerifyGetKey> => {
    if (!fresh && local && Date.now() - local.at < JWKS_MAX_AGE_S * 1000) return local.get
    let body: { keys: Array<JWK> } | undefined
    if (!fresh) {
      const hit = await cache()?.match(url).catch(() => undefined)
      if (hit) body = (await hit.json()) as { keys: Array<JWK> }
    }
    body ??= await fromStack()
    local = { at: Date.now(), get: createLocalJWKSet(body) }
    return local.get
  }
  return {
    get: async (header, token) => (await load(false))(header, token),
    reload: async () => {
      await load(true)
    }
  }
}

const stackKeys = (env: Env, projectId: string): KeySet => {
  if (env.ENVIRONMENT === "test" && env.STACK_TEST_JWKS) return { get: createLocalJWKSet(JSON.parse(env.STACK_TEST_JWKS) as { keys: Array<JWK> }) }
  let keys = keySets.get(projectId)
  if (!keys) {
    keys = sharedJwks(projectId)
    keySets.set(projectId, keys)
  }
  return keys
}

/** Bearer header, or the `bearer.<token>` WebSocket subprotocol (PROTOCOL.md "Identity and auth"). */
export const bearerOf = (req: Request): { token: string; viaSubprotocol: boolean } | undefined => {
  const h = req.headers.get("authorization")
  if (h?.toLowerCase().startsWith("bearer ")) return { token: h.slice(7).trim(), viaSubprotocol: false }
  const protos = (req.headers.get("sec-websocket-protocol") ?? "").split(",").map((s) => s.trim())
  const b = protos.find((p) => p.startsWith("bearer."))
  return b ? { token: b.slice(7), viaSubprotocol: true } : undefined
}

/** Why a token was refused, for the 401 message and the log (never the token or its subject). */
export type Rejection = "malformed" | "unknown_project" | "expired" | "not_yet_valid" | "bad_claims" | "unknown_key" | "keys_unavailable" | "bad_signature" | "anonymous" | "restricted"

/** Errors where refetching the project's keys can help: a key Stack added since the cached set, or a fetch that failed. */
const KEY_RETRY = new Set(["ERR_JWKS_NO_MATCHING_KEY", "ERR_JWKS_TIMEOUT", "ERR_JWKS_INVALID", "ERR_JOSE_GENERIC"])

const rejectionOf = (e: unknown): Rejection => {
  const code = (e as { code?: string } | null)?.code
  switch (code) {
    case "ERR_JWT_EXPIRED":
      return "expired"
    case "ERR_JWT_CLAIM_VALIDATION_FAILED":
      return (e as { claim?: string }).claim === "nbf" || (e as { claim?: string }).claim === "iat" ? "not_yet_valid" : "bad_claims"
    case "ERR_JWKS_NO_MATCHING_KEY":
      return "unknown_key"
    case "ERR_JWS_SIGNATURE_VERIFICATION_FAILED":
      return "bad_signature"
    case "ERR_JWT_INVALID":
    case "ERR_JWS_INVALID":
      return "malformed"
    default:
      // A JWKS fetch that failed or timed out (a network TypeError has no code).
      return "keys_unavailable"
  }
}

/**
 * Verifies `token` against one project's keys. When the keys cannot verify it because Stack published a
 * key after the cached set was fetched, or the fetch itself failed, the set is refetched once at once
 * (jose's own refetch waits out a 30 s cooldown) and the token tried again.
 */
export const verifyWithKeys = async (token: string, keys: KeySet, project: string): Promise<{ ok: true; payload: JWTPayload } | { ok: false; rejection: Rejection }> => {
  const options = { algorithms: ["ES256"], issuer: issuerOf(project), audience: project, clockTolerance: 60 }
  try {
    return { ok: true, payload: (await jwtVerify(token, keys.get, options)).payload }
  } catch (first) {
    const code = (first as { code?: string } | null)?.code
    if (!keys.reload || !(code === undefined || KEY_RETRY.has(code))) return { ok: false, rejection: rejectionOf(first) }
    try {
      await keys.reload()
      return { ok: true, payload: (await jwtVerify(token, keys.get, options)).payload }
    } catch (second) {
      return { ok: false, rejection: rejectionOf(second) }
    }
  }
}

/** The token's own claims and header, unverified: only to explain a refusal. */
const peek = (token: string): { kid?: string; restricted: boolean; anonymous: boolean } => {
  try {
    const claims = decodeJwt(token)
    const kid = decodeProtectedHeader(token).kid
    return { ...(kid ? { kid } : {}), restricted: claims.is_restricted === true, anonymous: claims.is_anonymous === true }
  } catch {
    return { restricted: false, anonymous: false }
  }
}

/**
 * Verifies a Stack access token from any configured project. The unverified `iss` only picks which
 * project's JWKS to try; the signature, issuer and audience are then checked against that project, so a
 * token never verifies under another project's keys or claims.
 */
export const authenticate = async (env: Env, token: string): Promise<{ caller: Caller } | { rejection: Rejection }> => {
  if (!token) return { rejection: "malformed" }
  let iss: string | undefined
  try {
    iss = decodeJwt(token).iss
  } catch {
    return { rejection: "malformed" }
  }
  const project = stackProjects(env).find((p) => issuerOf(p.id) === iss)
  if (!project) return { rejection: "unknown_project" }
  const result = await verifyWithKeys(token, stackKeys(env, project.id), project.id)
  const seen = peek(token)
  // A restricted user (sign-up not finished, e.g. an unverified email) gets tokens signed by keys outside
  // the default JWKS, so they fail as an unknown key; name the actual reason.
  const rejection: Rejection | undefined = !result.ok ? (seen.restricted ? "restricted" : result.rejection) : seen.anonymous ? "anonymous" : seen.restricted ? "restricted" : undefined
  if (rejection || !result.ok) {
    console.log(JSON.stringify({ msg: "token rejected", project: project.label, rejection, kid: seen.kid ?? null }))
    return { rejection: rejection ?? "bad_claims" }
  }
  const sub = result.payload.sub
  if (typeof sub !== "string" || !sub || result.payload.is_anonymous === true) return { rejection: "anonymous" }
  return { caller: { userId: sub, projectId: project.id, token } }
}

/** `authenticate` without the reason. */
export const verifyStackToken = async (env: Env, token: string): Promise<Caller | undefined> => {
  const r = await authenticate(env, token)
  return "caller" in r ? r.caller : undefined
}
