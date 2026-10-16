import { createLocalJWKSet, jwtVerify, SignJWT, type JWK } from "jose"
import { issuer, publicJwks, signer } from "../auth.ts"
import type { Env } from "../env.ts"

/**
 * A short-lived model gateway token for one Chief run (Lawrence 2026-10-15: agents a Chief starts on a
 * hand get the gateway, never a raw provider key). It is scoped to (team, chief, owner, run) and is
 * accepted only by the gateway's HTTP route (audience `model-gateway`, type `cmux-gw+jwt`), so it can
 * never act as an API token. Spend through it goes through the team's prepaid credits like any call.
 *
 * The hand passes it to the agent as ANTHROPIC_AUTH_TOKEN with ANTHROPIC_BASE_URL = gatewayBaseUrl().
 */
export const RUN_TOKEN_AUDIENCE = "model-gateway"
const TYP = "cmux-gw+jwt"
/** Default life: a long agent turn, not a standing credential. */
export const RUN_TOKEN_TTL_SECONDS = 2 * 3600
const ID = /^[A-Za-z0-9_.:-]{1,128}$/

export interface RunScope {
  readonly team: string
  readonly chief: string
  readonly owner: string
  readonly run: string
  readonly conversation?: string
}

export const mintRunToken = async (env: Env, s: RunScope, ttlSeconds = RUN_TOKEN_TTL_SECONDS): Promise<{ token: string; expires_at: number }> => {
  for (const v of [s.team, s.chief, s.owner, s.run]) if (!ID.test(v)) throw new Error("run token: invalid scope id")
  const { key, kid } = await signer(env)
  const now = Math.floor(Date.now() / 1000)
  const exp = now + Math.max(60, Math.min(ttlSeconds, 12 * 3600))
  const token = await new SignJWT({ team: s.team, chf: s.chief, run: s.run, ...(s.conversation ? { conv: s.conversation } : {}) })
    .setProtectedHeader({ alg: "ES256", kid, typ: TYP })
    .setIssuer(issuer(env))
    .setAudience(RUN_TOKEN_AUDIENCE)
    .setSubject(s.owner)
    .setIssuedAt(now)
    .setExpirationTime(exp)
    .sign(key)
  return { token, expires_at: exp * 1000 }
}

/** The run scope of a valid run token, or null (wrong audience or type, expired, bad signature). */
export const verifyRunToken = async (env: Env, token: string): Promise<RunScope | null> => {
  try {
    const { payload, protectedHeader } = await jwtVerify(token, createLocalJWKSet(publicJwks(env) as { keys: Array<JWK> }), { algorithms: ["ES256"], issuer: issuer(env), audience: RUN_TOKEN_AUDIENCE, typ: TYP, clockTolerance: 30 })
    const p = payload as { team?: unknown; chf?: unknown; run?: unknown; conv?: unknown; sub?: unknown }
    if (protectedHeader.typ !== TYP || typeof p.team !== "string" || typeof p.chf !== "string" || typeof p.run !== "string" || typeof p.sub !== "string") return null
    return { team: p.team, chief: p.chf, owner: p.sub, run: p.run, ...(typeof p.conv === "string" ? { conversation: p.conv } : {}) }
  } catch {
    return null
  }
}

/** ANTHROPIC_BASE_URL for an agent: the API origin's gateway prefix (the client appends /v1/messages). */
export const gatewayBaseUrl = (env: Env): string => `${(env.CLOUD_API_ORIGIN ?? "").replace(/\/$/, "")}/v1/model-gateway`
