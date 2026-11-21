import { importJWK, jwtVerify, SignJWT, type JWK } from "jose"
import { INTEGRATION_ATTEMPT_PATTERN, isConnectReturnTo } from "@cmux/protocol"
import type { BuildSpace, Env } from "../env.ts"
import { isDevSpace, parseBuildSpace } from "../build-space.ts"
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
  /** A connect the app finishes itself: the hash of the app's attempt secret (integration.connect `attempt_hash`). */
  readonly attempt_hash?: string
  /**
   * The dev build space the connect ran in (build-space.ts); absent for the base space (nightly, stable). The console's
   * hand-off carries no build space header, so the state says which space's ConnectionDO keeps the answer.
   */
  readonly build_space?: BuildSpace
}

/** A verified state, with when it was signed (seconds): a connection that turned active after it needs a fresh one. */
export type VerifiedState = ConnectState & { readonly issued_at: number }

/** The page provider redirects come back to: INTEGRATIONS_CALLBACK_ORIGIN when set (development), else DASHBOARD_ORIGIN. */
export const integrationCallbackUrl = (env: Pick<Env, "DASHBOARD_ORIGIN" | "INTEGRATIONS_CALLBACK_ORIGIN">): string =>
  `${(env.INTEGRATIONS_CALLBACK_ORIGIN || env.DASHBOARD_ORIGIN || "").replace(/\/$/, "")}/integrations/callback`

const AUDIENCE = "cmux-integration-state"
export const STATE_TTL_SECONDS = 15 * 60

/** What signing and verifying a state reads: the API key and the environment (a raw or a spaced env). */
type StateEnv = Pick<Env, "JWT_PRIVATE_JWK" | "ENVIRONMENT">

const keys = (env: StateEnv) => {
  const jwk = JSON.parse(env.JWT_PRIVATE_JWK) as JWK
  const { d: _d, ...pub } = jwk
  return { priv: jwk, pub }
}

export const signState = async (env: StateEnv, s: ConnectState): Promise<string> => {
  const key = await importJWK(keys(env).priv, "ES256")
  return new SignJWT({ conn: s.conn, team: s.team, provider: s.provider, ...(s.return_to ? { ret: s.return_to } : {}), ...(s.installation ? { inst: s.installation } : {}), ...(s.repo ? { repo: s.repo } : {}), ...(s.configure_url ? { cfg: s.configure_url } : {}), ...(s.attempt_hash ? { anh: s.attempt_hash } : {}), ...(isDevSpace(s.build_space) ? { bsp: s.build_space } : {}) })
    .setProtectedHeader({ alg: "ES256", typ: "JWT" })
    .setIssuer(`https://cmux-api/${env.ENVIRONMENT}`)
    .setAudience(AUDIENCE)
    .setSubject(s.user)
    .setIssuedAt()
    .setExpirationTime(`${STATE_TTL_SECONDS}s`)
    .sign(key)
}

export const verifyState = async (env: StateEnv, token: string): Promise<VerifiedState | undefined> => {
  try {
    const { payload } = await jwtVerify(token, await importJWK(keys(env).pub, "ES256"), { algorithms: ["ES256"], audience: AUDIENCE, issuer: `https://cmux-api/${env.ENVIRONMENT}` })
    const { conn, team, provider, sub, ret, inst, repo, cfg, anh, bsp, iat } = payload as Record<string, unknown>
    // Only a dev space is ever signed (the base space is its absence).
    const space = bsp === undefined ? undefined : typeof bsp === "string" ? parseBuildSpace(bsp) : null
    if (space === null || (space !== undefined && !isDevSpace(space))) return undefined
    if (typeof conn !== "string" || typeof team !== "string" || typeof provider !== "string" || typeof sub !== "string") return undefined
    if (typeof iat !== "number" || !Number.isFinite(iat)) return undefined
    if (anh !== undefined && !(typeof anh === "string" && INTEGRATION_ATTEMPT_PATTERN.test(anh))) return undefined
    if (ret !== undefined && !isConnectReturnTo(ret)) return undefined
    if (inst !== undefined && !(typeof inst === "number" && Number.isSafeInteger(inst) && inst > 0)) return undefined
    if (repo !== undefined && !(typeof repo === "string" && /^[A-Za-z0-9_.-]{1,100}\/[A-Za-z0-9_.-]{1,100}$/.test(repo))) return undefined
    if (cfg !== undefined && !(typeof cfg === "string" && GITHUB_CONFIGURE_URL.test(cfg))) return undefined
    return {
      conn, team, provider, user: sub, issued_at: iat,
      ...(ret === undefined ? {} : { return_to: ret }),
      ...(anh === undefined ? {} : { attempt_hash: anh }),
      ...(inst === undefined ? {} : { installation: inst }),
      ...(repo === undefined ? {} : { repo }),
      ...(cfg === undefined ? {} : { configure_url: cfg }),
      ...(space === undefined ? {} : { build_space: space })
    }
  } catch {
    return undefined
  }
}
