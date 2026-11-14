import { importJWK, jwtVerify, SignJWT, type JWK } from "jose"
import { isConnectReturnTo } from "@cmux/protocol"
import type { Env } from "../env.ts"
import { GITHUB_CONFIGURE_URL } from "./github-connect.ts"

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
  /** The chat's cmux deep link the callback page opens after linking (checked at connect and again here). */
  readonly return_to?: string
  /** GitHub: the App installation the server found covering the asked repository (the OAuth authorize path). */
  readonly installation?: number
  /** GitHub: the repository Connect was asked for, and that installation's configure page (opened when the link leaves it out). */
  readonly repo?: string
  readonly configure_url?: string
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
  return new SignJWT({ conn: s.conn, team: s.team, provider: s.provider, ...(s.return_to ? { ret: s.return_to } : {}), ...(s.installation ? { inst: s.installation } : {}), ...(s.repo ? { repo: s.repo } : {}), ...(s.configure_url ? { cfg: s.configure_url } : {}) })
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
    const { conn, team, provider, sub, ret, inst, repo, cfg } = payload as Record<string, unknown>
    if (typeof conn !== "string" || typeof team !== "string" || typeof provider !== "string" || typeof sub !== "string") return undefined
    if (ret !== undefined && !isConnectReturnTo(ret)) return undefined
    if (inst !== undefined && !(typeof inst === "number" && Number.isSafeInteger(inst) && inst > 0)) return undefined
    if (repo !== undefined && !(typeof repo === "string" && /^[A-Za-z0-9_.-]{1,100}\/[A-Za-z0-9_.-]{1,100}$/.test(repo))) return undefined
    if (cfg !== undefined && !(typeof cfg === "string" && GITHUB_CONFIGURE_URL.test(cfg))) return undefined
    return {
      conn, team, provider, user: sub,
      ...(ret === undefined ? {} : { return_to: ret }),
      ...(inst === undefined ? {} : { installation: inst }),
      ...(repo === undefined ? {} : { repo }),
      ...(cfg === undefined ? {} : { configure_url: cfg })
    }
  } catch {
    return undefined
  }
}
