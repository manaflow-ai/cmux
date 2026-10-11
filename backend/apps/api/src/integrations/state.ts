import { importJWK, jwtVerify, SignJWT, type JWK } from "jose"
import type { Env } from "../env.ts"

/**
 * The OAuth `state` of a connection attempt: a short-lived ES256 JWT signed by
 * the API key, bound to the connection, team, user and provider. The callback
 * goes to the dashboard, which calls `integration.complete` with the user's own
 * session, and the Worker refuses a state minted for another user (login CSRF).
 */

export interface ConnectState {
  readonly conn: string
  readonly team: string
  readonly user: string
  readonly provider: string
}

const AUDIENCE = "cmux-integration-state"
export const STATE_TTL_SECONDS = 15 * 60

const keys = (env: Env) => {
  const jwk = JSON.parse(env.JWT_PRIVATE_JWK) as JWK
  const { d: _d, ...pub } = jwk
  return { priv: jwk, pub }
}

export const signState = async (env: Env, s: ConnectState): Promise<string> => {
  const key = await importJWK(keys(env).priv, "ES256")
  return new SignJWT({ conn: s.conn, team: s.team, provider: s.provider })
    .setProtectedHeader({ alg: "ES256", typ: "JWT" })
    .setIssuer(`https://cmux-api/${env.ENVIRONMENT}`)
    .setAudience(AUDIENCE)
    .setSubject(s.user)
    .setIssuedAt()
    .setExpirationTime(`${STATE_TTL_SECONDS}s`)
    .sign(key)
}

export const verifyState = async (env: Env, token: string): Promise<ConnectState | undefined> => {
  try {
    const { payload } = await jwtVerify(token, await importJWK(keys(env).pub, "ES256"), { algorithms: ["ES256"], audience: AUDIENCE, issuer: `https://cmux-api/${env.ENVIRONMENT}` })
    const { conn, team, provider, sub } = payload as Record<string, unknown>
    if (typeof conn !== "string" || typeof team !== "string" || typeof provider !== "string" || typeof sub !== "string") return undefined
    return { conn, team, provider, user: sub }
  } catch {
    return undefined
  }
}
