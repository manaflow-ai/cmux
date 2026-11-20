import { createLocalJWKSet, createRemoteJWKSet, decodeJwt, errors as joseErrors, jwtVerify, type JWK, type JWTVerifyGetKey } from "jose"
import type { Env } from "./env.ts"
import { stackServer, type StackServer } from "./stack-server.ts"

/**
 * POST /v1/auth/github-actions: a GitHub Actions job signs in as one test account with the OIDC token
 * GitHub mints for it, so no Stack password is stored anywhere (hq#7076). The production Cloud journey
 * (.github/workflows/cloud-journey-prod.yml on main) uses it.
 *
 * The rows come from the plain Worker var CI_SESSION_TRUST (they hold no secret), a JSON array:
 *
 *   [{ "id": "ci-cloud-journey-prod", "audience": "https://cloud-api.cmux.dev",
 *      "repository": "manaflow-ai/cmux", "repositoryId": "1144115288", "ref": "refs/heads/main",
 *      "workflowRef": "manaflow-ai/cmux/.github/workflows/cloud-journey-prod.yml@refs/heads/main",
 *      "events": ["schedule", "workflow_dispatch"],
 *      "subject": "repo:manaflow-ai/cmux:ref:refs/heads/main", "stackUser": "<the test account's Stack user id>", "ttlSeconds": 2400 }]
 *
 * A token matches a row only when GitHub signed it (RS256, GitHub's own JWKS), it is unexpired and at
 * most 15 minutes old, its audience (one string), repository, repository_id, ref, workflow_ref and
 * job_workflow_ref all equal the row's, its sub equals the row's `subject` exactly (so a job run under an
 * environment, `repo:<repo>:environment:<name>`, or with any other subject is refused), and its event_name is one of the row's `events`. The events
 * keep out a pull_request_target (or any other) run of the trusted file at the trusted ref, which
 * could execute a fork's code, even if that trigger is ever added to the file. A token from another repository, ref or
 * workflow (a fork, a branch's copy of the file, a reusable workflow called from elsewhere) matches
 * nothing. Each token signs in once: its jti is recorded until it expires, and a second use is refused.
 * The answer is a Stack session for the row's one user that Stack ends after `ttlSeconds`
 * (at most an hour), so it dies with the run; only the access token is returned, never the refresh token.
 * Every refusal is the same 401: a caller learns nothing about the rows.
 *
 * This is not the cmux-vm `ci-product-smoke` principal (workers/cmux-vm/src/auth/ci-trust.ts): that one is
 * a VM-scoped service principal of the cmux-vm Worker and cannot open a Stack session. The verification
 * follows it, minus the `environment` claim (the journey's job runs without an environment).
 */

export const GITHUB_ACTIONS_ISSUER = "https://token.actions.githubusercontent.com"
export const CI_SESSION_PATH = "/v1/auth/github-actions"
/** GitHub's job tokens live about five minutes; anything older is refused even if unexpired. */
const MAX_TOKEN_AGE = "15m"
const MAX_TTL_SECONDS = 3600

export interface CiSessionRow {
  readonly id: string
  readonly audience: string
  readonly repository: string
  readonly repositoryId: string
  readonly ref: string
  readonly workflowRef: string
  readonly events: ReadonlyArray<string>
  /** The token's whole `sub`, e.g. `repo:manaflow-ai/cmux:ref:refs/heads/main` for a job with no environment. */
  readonly subject: string
  readonly stackUser: string
  readonly ttlSeconds: number
}

const ID = /^ci-[a-z0-9-]{1,37}$/
const AUDIENCE = /^https:\/\/[a-z0-9.-]+$/
const REPOSITORY = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/
const REF = /^refs\/(heads|tags)\/[A-Za-z0-9_./-]+$/
const WORKFLOW_REF = /^([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)\/\.github\/workflows\/[A-Za-z0-9_.-]+\.ya?ml@(refs\/[A-Za-z0-9_./-]+)$/
const STACK_USER = /^[A-Za-z0-9_-]{1,64}$/
/** Events a row may trust: none of them runs code from a pull request's head or a fork. */
const TRUSTABLE_EVENTS = new Set(["schedule", "workflow_dispatch", "push"])

const validRow = (value: unknown): value is CiSessionRow => {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false
  const r = value as Record<string, unknown>
  const known = new Set(["id", "audience", "repository", "repositoryId", "ref", "workflowRef", "events", "subject", "stackUser", "ttlSeconds"])
  if (Object.keys(r).some((k) => !known.has(k))) return false
  const str = (k: string, re: RegExp) => typeof r[k] === "string" && re.test(r[k] as string)
  if (!str("id", ID) || !str("audience", AUDIENCE) || !str("repository", REPOSITORY) || !str("ref", REF) || !str("stackUser", STACK_USER)) return false
  if (!str("repositoryId", /^[0-9]{1,20}$/)) return false
  // The subject names the row's own repository; no wildcard is possible since it is compared whole.
  if (typeof r.subject !== "string" || !r.subject.startsWith(`repo:${String(r.repository)}:`) || !/^[A-Za-z0-9_.:/@-]{1,256}$/.test(r.subject)) return false
  if (!Array.isArray(r.events) || r.events.length === 0 || !r.events.every((e) => typeof e === "string" && TRUSTABLE_EVENTS.has(e))) return false
  // The workflow file must live in the row's repository and run from the row's ref.
  const wf = typeof r.workflowRef === "string" ? WORKFLOW_REF.exec(r.workflowRef) : null
  if (!wf || wf[1] !== r.repository || wf[2] !== r.ref) return false
  return typeof r.ttlSeconds === "number" && Number.isInteger(r.ttlSeconds) && r.ttlSeconds >= 60 && r.ttlSeconds <= MAX_TTL_SECONDS
}

/** Parses CI_SESSION_TRUST. Absent or blank: no rows. Invalid (any row): none, and `ok` is false. */
export const parseCiSessionTrust = (raw: string | undefined): { readonly ok: boolean; readonly rows: ReadonlyArray<CiSessionRow> } => {
  if (raw === undefined || raw.trim().length === 0) return { ok: true, rows: [] }
  let json: unknown
  try {
    json = JSON.parse(raw)
  } catch {
    return { ok: false, rows: [] }
  }
  if (!Array.isArray(json) || !json.every(validRow) || new Set(json.map((r) => r.id)).size !== json.length) return { ok: false, rows: [] }
  return { ok: true, rows: json }
}

/** GitHub's signing keys could not be read (network, HTTP status, timeout, bad JWKS): says nothing about the caller. */
export class CiKeysUnavailable extends Error {}

/** Every key lookup failure except "no such key" means the keys are unavailable, not that the token is bad. */
const keysOrUnavailable = (getKey: JWTVerifyGetKey): JWTVerifyGetKey => async (header, token) => {
  try {
    return await getKey(header, token)
  } catch (error) {
    if (error instanceof joseErrors.JWKSNoMatchingKey || error instanceof joseErrors.JWKSMultipleMatchingKeys) throw error
    throw new CiKeysUnavailable()
  }
}

export type CiSessionRefusal = "not-github" | "no-trust" | "invalid" | "no-match" | "replay"

/** The row a GitHub Actions token matches, or why it matches none. Claims come from jwtVerify only. */
export const matchCiSessionToken = async (
  raw: string,
  rows: ReadonlyArray<CiSessionRow>,
  getKey: JWTVerifyGetKey,
  now: Date = new Date()
): Promise<{ ok: true; row: CiSessionRow; jti: string; expiresAt: number; runId?: string } | { ok: false; reason: CiSessionRefusal }> => {
  try {
    if (decodeJwt(raw).iss !== GITHUB_ACTIONS_ISSUER) return { ok: false, reason: "not-github" }
  } catch {
    return { ok: false, reason: "not-github" }
  }
  if (rows.length === 0) return { ok: false, reason: "no-trust" }
  let payload: Record<string, unknown>
  try {
    ;({ payload } = await jwtVerify(raw, keysOrUnavailable(getKey), {
      algorithms: ["RS256"],
      issuer: GITHUB_ACTIONS_ISSUER,
      audience: [...new Set(rows.map((r) => r.audience))],
      clockTolerance: 60,
      maxTokenAge: MAX_TOKEN_AGE,
      currentDate: now,
      requiredClaims: ["exp", "iat", "jti", "sub", "repository", "repository_id", "ref", "workflow_ref", "event_name"]
    }))
  } catch (error) {
    if (error instanceof CiKeysUnavailable) throw error
    if (error instanceof joseErrors.JOSEError) return { ok: false, reason: "invalid" }
    throw error
  }
  const row = rows.find(
    (r) =>
      // GitHub sends one audience, as a string; a list is not what the job asked for.
      payload.aud === r.audience &&
      payload.sub === r.subject &&
      payload.repository === r.repository &&
      payload.repository_id === r.repositoryId &&
      typeof payload.event_name === "string" &&
      r.events.includes(payload.event_name) &&
      payload.ref === r.ref &&
      payload.workflow_ref === r.workflowRef &&
      // The job itself must be defined in the row's file: a job from a reusable workflow names that file here.
      // GitHub may leave the claim out for a job of the calling file itself; then workflow_ref alone binds it.
      (payload.job_workflow_ref === undefined || payload.job_workflow_ref === r.workflowRef)
  )
  if (!row || typeof payload.jti !== "string" || payload.jti.length === 0 || typeof payload.exp !== "number") return { ok: false, reason: "no-match" }
  return { ok: true, row, jti: payload.jti, expiresAt: payload.exp * 1000, ...(typeof payload.run_id === "string" ? { runId: payload.run_id } : {}) }
}

let githubKeys: JWTVerifyGetKey | undefined
const githubJwks = (env: Env): JWTVerifyGetKey => {
  if (env.ENVIRONMENT === "test" && env.GITHUB_ACTIONS_TEST_JWKS) return createLocalJWKSet(JSON.parse(env.GITHUB_ACTIONS_TEST_JWKS) as { keys: Array<JWK> })
  // jose refetches on an unknown kid (rotation), at most once per cooldown.
  githubKeys ??= createRemoteJWKSet(new URL(`${GITHUB_ACTIONS_ISSUER}/.well-known/jwks`), { cacheMaxAge: 60 * 60_000, cooldownDuration: 30_000 })
  return githubKeys
}

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } })

export interface CiSessionDeps {
  readonly getKey?: JWTVerifyGetKey
  readonly stack?: StackServer
  readonly now?: () => Date
  /** True the first time a token id is seen before `expiresAt` (default: WireTicketDO.claimOnce on its own object). */
  readonly claimOnce?: (jti: string, expiresAt: number, now: number) => Promise<boolean>
}

const sha256Hex = async (s: string) =>
  Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s))), (b) => b.toString(16).padStart(2, "0")).join("")

const claimInDo = (env: Env) => async (jti: string, expiresAt: number, now: number) => {
  const ns = env.WIRE_TICKET_DO
  // Past exp plus the verifier's clock tolerance, so an unexpired token can never be seen as new again.
  return ns.get(ns.idFromName("ci-session-jti")).claimOnce(`ci-jti:${await sha256Hex(jti)}`, expiresAt + 120_000, now)
}

export const handleCiSession = async (request: Request, env: Env, deps: CiSessionDeps = {}): Promise<Response> => {
  if (request.method !== "POST") return json({ error: "method not allowed" }, 405)
  const token = request.headers.get("authorization")?.match(/^Bearer ([A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)$/)?.[1]
  if (!token) return json({ error: "a GitHub Actions OIDC token is required" }, 401)
  const parsed = parseCiSessionTrust(env.CI_SESSION_TRUST)
  if (!parsed.ok) console.error("cmux-api CI_SESSION_TRUST is invalid; no CI job is trusted")
  let match: Awaited<ReturnType<typeof matchCiSessionToken>>
  try {
    match = await matchCiSessionToken(token, parsed.rows, deps.getKey ?? githubJwks(env), deps.now?.() ?? new Date())
  } catch {
    // GitHub's JWKS could not be read: says nothing about the caller.
    return json({ error: "GitHub's signing keys are unavailable; try again" }, 503)
  }
  if (match.ok && !(await (deps.claimOnce ?? claimInDo(env))(match.jti, match.expiresAt, (deps.now?.() ?? new Date()).getTime()))) {
    match = { ok: false, reason: "replay" }
  }
  if (!match.ok) {
    console.warn(JSON.stringify({ event: "ci_session.refused", reason: match.reason }))
    return json({ error: "this token is not trusted to sign in" }, 401)
  }
  const stack = deps.stack ?? stackServer(env)
  if (!stack) return json({ error: "Stack server access is not configured on this deployment" }, 503)
  const session = await stack.createSession(match.row.stackUser, match.row.ttlSeconds * 1000)
  const sessionEnds = (deps.now?.() ?? new Date()).getTime() + match.row.ttlSeconds * 1000
  let accessExp: number | undefined
  try {
    accessExp = decodeJwt(session.access_token).exp
  } catch {
    accessExp = undefined
  }
  console.log(JSON.stringify({ event: "ci_session.opened", row: match.row.id, run_id: match.runId ?? null, ttl_s: match.row.ttlSeconds }))
  return json({
    access_token: session.access_token,
    user: match.row.stackUser,
    expires_at: new Date(Math.min(sessionEnds, accessExp ? accessExp * 1000 : sessionEnds)).toISOString(),
    session_expires_at: new Date(sessionEnds).toISOString()
  })
}
