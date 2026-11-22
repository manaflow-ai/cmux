import { authenticate } from "./auth.ts"
import { DEVICE_LABEL, teamOfHandoffCode, type HandoffError, type Minted, type Redeemed } from "./auth-handoff.ts"
import { personalTeamIdFor } from "./domains/user.ts"
import type { Env } from "./env.ts"
import { isHumanSession } from "./pair-op-reply.ts"
import { signInRules, ssoTeams } from "./policy-gate.ts"

/**
 * Sign-in hand-off routes (auth-handoff.ts). Errors are `{error: {code, message}}`, never cached.
 *
 *   POST /v1/auth/handoffs        {device?}  (a human Stack session bearer: never an install token or an agent)
 *        -> 201 {code, expires_at, user, email, device}
 *        401 auth.unauthenticated, 403 auth_handoff.human_session_required, 403 auth.sso_required (an account an
 *        SSO-enforcing team binds signs in with its SSO on each device), 409 auth_handoff.no_account,
 *        429 auth_handoff.rate_limited (5 per 10 min), 503 owner.unreachable
 *   POST /v1/auth/handoffs/redeem {code, device?, expected_user?}  (no bearer: the code is the credential)
 *        -> 200 {already_signed_in, access_token?, refresh_token?, user, stack_user, email, device, minted_device}
 *        (already_signed_in: expected_user is the code's user; the code is spent, no session is made)
 *        400 auth_handoff.invalid (unknown, spent or expired, one answer for all), 409 auth_handoff.other_user
 *        (the code is not spent), 429 rate limited (per IP), 503 auth_handoff.unavailable
 */
export const AUTH_HANDOFFS_PATH = "/v1/auth/handoffs"
export const AUTH_HANDOFFS_REDEEM_PATH = "/v1/auth/handoffs/redeem"

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store", "referrer-policy": "no-referrer" } })
const failure = (code: string, message: string, status: number) => json({ error: { code, message } }, status)

const STATUS: Readonly<Record<HandoffError["code"], number>> = {
  "auth_handoff.no_account": 409,
  "auth_handoff.rate_limited": 429,
  "auth_handoff.invalid": 400,
  "auth_handoff.other_user": 409,
  "auth_handoff.unavailable": 503
}

const body = async (request: Request): Promise<Record<string, unknown> | undefined> => {
  const raw = (await request.json().catch(() => undefined)) as unknown
  return raw && typeof raw === "object" && !Array.isArray(raw) ? (raw as Record<string, unknown>) : undefined
}

/** An optional device label: absent, or a short printable string; anything else is a bad request. */
const deviceOf = (value: unknown): { ok: true; device: string | undefined } | { ok: false } => {
  if (value === undefined || value === null) return { ok: true, device: undefined }
  if (typeof value !== "string") return { ok: false }
  const trimmed = value.trim()
  if (!trimmed) return { ok: true, device: undefined }
  return DEVICE_LABEL.test(trimmed) ? { ok: true, device: trimmed } : { ok: false }
}

/** Whether a team that requires SSO binds this person (their own team or their email domain's owner). */
const ssoBound = async (env: Env, principal: Parameters<typeof ssoTeams>[1]): Promise<boolean> => {
  for (const { team, domain } of await ssoTeams(env, principal)) {
    if ((await signInRules(env, team, principal.user!, domain)).sso_required) return true
  }
  return false
}

export const handleAuthHandoffMint = async (request: Request, env: Env): Promise<Response> => {
  if (request.method !== "POST") return failure("validation.invalid", "method not allowed", 405)
  const auth = request.headers.get("authorization") ?? ""
  const principal = await authenticate(env, auth.startsWith("Bearer ") ? auth.slice(7) : undefined)
  if (!principal?.user) return failure("auth.unauthenticated", "a signed-in cmux session is required", 401)
  // The app's own human Stack session only: an install token (`cmux auth token`) or an agent never mints.
  if (!isHumanSession(principal) || !principal.stack_user_id) {
    return failure("auth_handoff.human_session_required", "only the signed-in cmux app's own session can hand off a sign-in", 403)
  }
  let bound: boolean
  try {
    bound = await ssoBound(env, principal)
  } catch (e) {
    console.error(JSON.stringify({ msg: "auth handoff sso check unreachable", error: String(e) }))
    return failure("owner.unreachable", "the sign-in policy could not be checked; retry", 503)
  }
  if (bound) return failure("auth.sso_required", "your organization requires sign-in with its SSO on each device", 403)
  const b = (await body(request)) ?? {}
  const device = deviceOf(b.device)
  if (!device.ok) return failure("validation.invalid", "device is a name of at most 64 printable characters", 400)
  const team = personalTeamIdFor(principal.user)
  let r: Minted | HandoffError
  try {
    r = await env.TEAM_DO.get(env.TEAM_DO.idFromName(team)).authHandoffMint(team, {
      user: principal.user,
      stack_user: principal.stack_user_id,
      email: principal.email ?? null,
      session: principal.stack_session,
      device: device.device
    })
  } catch (e) {
    console.error(JSON.stringify({ msg: "auth handoff mint unreachable", error: String(e) }))
    return failure("owner.unreachable", "cmux could not mint a code; retry", 503)
  }
  if (!r.ok) return failure(r.code, r.message, STATUS[r.code])
  return json({ code: r.code, expires_at: r.expires_at, user: r.user, email: r.email, device: r.device }, 201)
}

export const handleAuthHandoffRedeem = async (request: Request, env: Env): Promise<Response> => {
  if (request.method !== "POST") return failure("validation.invalid", "method not allowed", 405)
  // Per client IP, before any TeamDO wakes (code guessing).
  if (env.SSO_DISCOVER_LIMIT) {
    const { success } = await env.SSO_DISCOVER_LIMIT.limit({ key: `auth-handoff:${request.headers.get("cf-connecting-ip") ?? "unknown"}` })
    if (!success) return failure("auth_handoff.rate_limited", "too many attempts; wait a minute", 429)
  }
  const b = (await body(request)) ?? {}
  const code = typeof b.code === "string" ? b.code : ""
  const team = teamOfHandoffCode(code)
  const device = deviceOf(b.device)
  const expected = b.expected_user === undefined || b.expected_user === null ? undefined : b.expected_user
  if (expected !== undefined && (typeof expected !== "string" || expected.length === 0 || expected.length > 128)) {
    return failure("validation.invalid", "expected_user is the Stack user id the device is signed in as", 400)
  }
  if (!device.ok) return failure("validation.invalid", "device is a name of at most 64 printable characters", 400)
  if (!team) return failure("auth_handoff.invalid", "the hand-off code expired, was used, or is not a code", 400)
  let r: Redeemed | HandoffError
  try {
    r = await env.TEAM_DO.get(env.TEAM_DO.idFromName(team)).authHandoffRedeem(team, { code, device: device.device, expected_user: expected as string | undefined })
  } catch (e) {
    console.error(JSON.stringify({ msg: "auth handoff redeem unreachable", error: String(e) }))
    return failure("auth_handoff.unavailable", "cmux could not redeem the code; mint a new one and retry", 503)
  }
  if (!r.ok) return failure(r.code, r.message, STATUS[r.code])
  const { ok: _ok, ...answer } = r
  return json(answer)
}
