import { createLocalJWKSet, jwtVerify, SignJWT, type JWK } from "jose"
import { issuer, publicJwks, signer } from "../auth.ts"
import type { Env } from "../env.ts"
import type { LedgerAnswer, LedgerOp } from "./run-ledger.ts"

/**
 * A short-lived model gateway token for one Chief run (Lawrence 2026-10-15: agents a Chief starts on a
 * hand get the gateway, never a raw provider key). It is scoped to (team, chief, owner, run) and is
 * accepted only by the gateway's HTTP route (audience `model-gateway`, type `cmux-gw+jwt`), so it can
 * never act as an API token. Spend through it goes through the team's prepaid credits like any call.
 *
 * It works only while its run runs (the run's end or a cancel revokes it: every later call is
 * refused; a stream already open finishes, bounded by that call's held maximum) and within its spend
 * cap (claim `cap`, USD, never above CHIEF_RUN_TOKEN_CAP_USD; run-ledger.ts in the run's brain object).
 * The hand passes it to the agent as ANTHROPIC_AUTH_TOKEN with ANTHROPIC_BASE_URL = gatewayBaseUrl().
 */
export const RUN_TOKEN_AUDIENCE = "model-gateway"
const TYP = "cmux-gw+jwt"
/** Default life: a long agent turn, not a standing credential. */
export const RUN_TOKEN_TTL_SECONDS = 2 * 3600
/** An agent token's ceiling: the session revokes it earlier; this bounds a session that never reports its end. */
export const AGENT_TOKEN_TTL_SECONDS = 12 * 3600
const ID = /^[A-Za-z0-9_.:-]{1,128}$/

export interface RunScope {
  readonly team: string
  readonly chief: string
  readonly owner: string
  readonly run: string
  /** The run's conversation: names the brain object that holds the run (its status and the token's ledger). */
  readonly conversation: string
}
/** A verified run token: its scope, its id and its spend cap (USD). */
export interface RunGrant extends RunScope {
  readonly jti: string
  readonly cap_usd: number
  /** An agent token: valid while its agent session lives (run-ledger.ts), not only its brain turn. */
  readonly agent: boolean
}
/** Default spend cap of one run token (USD); CHIEF_RUN_TOKEN_CAP_USD overrides. */
export const runTokenCap = (env: Env): number => {
  const n = Number(env.CHIEF_RUN_TOKEN_CAP_USD ?? "5")
  return Number.isFinite(n) && n > 0 && n <= 500 ? n : 5
}

export const mintRunToken = async (env: Env, s: RunScope, opts: { readonly ttlSeconds?: number; readonly capUsd?: number; readonly agent?: boolean } = {}): Promise<{ token: string; jti: string; expires_at: number; cap_usd: number }> => {
  for (const v of [s.team, s.chief, s.owner, s.run, s.conversation]) if (!ID.test(v)) throw new Error("run token: invalid scope id")
  const ttlSeconds = opts.ttlSeconds ?? RUN_TOKEN_TTL_SECONDS
  const cap = Math.min(opts.capUsd ?? runTokenCap(env), runTokenCap(env))
  const { key, kid } = await signer(env)
  const now = Math.floor(Date.now() / 1000)
  const exp = now + Math.max(60, Math.min(ttlSeconds, 12 * 3600))
  const jti = crypto.randomUUID()
  const token = await new SignJWT({ team: s.team, chf: s.chief, run: s.run, conv: s.conversation, cap, ...(opts.agent ? { knd: "agent" } : {}) })
    .setJti(jti)
    .setProtectedHeader({ alg: "ES256", kid, typ: TYP })
    .setIssuer(issuer(env))
    .setAudience(RUN_TOKEN_AUDIENCE)
    .setSubject(s.owner)
    .setIssuedAt(now)
    .setExpirationTime(exp)
    .sign(key)
  return { token, jti, expires_at: exp * 1000, cap_usd: cap }
}

/** The run scope of a valid run token, or null (wrong audience or type, expired, bad signature). */
export const verifyRunToken = async (env: Env, token: string): Promise<RunGrant | null> => {
  try {
    const { payload, protectedHeader } = await jwtVerify(token, createLocalJWKSet(publicJwks(env) as { keys: Array<JWK> }), { algorithms: ["ES256"], issuer: issuer(env), audience: RUN_TOKEN_AUDIENCE, typ: TYP, clockTolerance: 30 })
    const p = payload as { team?: unknown; chf?: unknown; run?: unknown; conv?: unknown; sub?: unknown; jti?: unknown; cap?: unknown; knd?: unknown }
    if (protectedHeader.typ !== TYP || typeof p.team !== "string" || typeof p.chf !== "string" || typeof p.run !== "string" || typeof p.sub !== "string" || typeof p.conv !== "string" || typeof p.jti !== "string" || typeof p.cap !== "number" || !(p.cap > 0)) return null
    // A lower deployment cap applies to tokens already out, too.
    return { team: p.team, chief: p.chf, owner: p.sub, run: p.run, conversation: p.conv, jti: p.jti, cap_usd: Math.min(p.cap, runTokenCap(env)), agent: p.knd === "agent" }
  } catch {
    return null
  }
}

/** ANTHROPIC_BASE_URL for an agent: the API origin's gateway prefix (the client appends /v1/messages). */
export const gatewayBaseUrl = (env: Env): string => `${(env.CLOUD_API_ORIGIN ?? "").replace(/\/$/, "")}/v1/model-gateway`

/** The brain object that holds a run's tokens. */
const ledgerOf = (env: Env, chief: string, conversation: string) => env.CHIEF_BRAIN_DO.get(env.CHIEF_BRAIN_DO.idFromName(`${chief}/${conversation}`)) as unknown as { runToken(run: string, jti: string, cap: number, o: LedgerOp): Promise<LedgerAnswer> }

/**
 * The hand's session-end hook (1f-H): an agent session on `hand` ended, so every agent token bound to
 * it stops working at once. Also what the Chief's `agent cancel` calls.
 */
export const revokeAgentSession = (env: Env, chief: string, conversation: string, hand: string, session: string): Promise<LedgerAnswer> =>
  ledgerOf(env, chief, conversation).runToken("", "", 0, { op: "revoke", hand, session })
