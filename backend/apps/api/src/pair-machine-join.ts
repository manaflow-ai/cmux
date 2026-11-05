import type { Env } from "./env.ts"

/**
 * One credential for a paired box. Leo, 2026-11-05: "I don't want to deal with SSH keys. I just want the app to handle
 * the thing for me." A box paired with a code (`cmux pair CODE`, `cmux server pair`) gets, with its pairing result, a
 * single-use join token minted for the person who approved it, on the same issuer as `cmux machine add`
 * (cmux-platform POST /internal/v1/machines/join-tokens, over the PLATFORM service binding with INTERNAL_TOKEN). The
 * box redeems it at POST /v1/machines/join-tokens/redeem exactly as `acpmux host join` does, so both ways end in one
 * `cmm_` machine record, listed by `cmux machine list` and revoked by `cmux machine revoke` or `acpmux machine leave`.
 *
 * The token is a secret: it lives only in the PairingDO row (until the code's alarm deletes it) and the paired frame
 * pushed to the box's collect socket, never in an op result, owner event or log line.
 */

export interface PairMachineJoin {
  /** `cmj_…`, single use. */
  readonly token: string
  /** Epoch ms. */
  readonly expires_at: number
  /** The platform's id for the token (not a secret): the machine it makes is found, and revoked, by it. */
  readonly join_token_id: string
}

/** What the box's collect socket gets: the token and its expiry, nothing else. */
export const machineJoinFrame = (join: PairMachineJoin) => ({ token: join.token, expires_at: join.expires_at })

type Minted = { readonly ok: true; readonly join: PairMachineJoin | null } | { readonly ok: false; readonly code: string; readonly message: string; readonly retryable: boolean }

const TOKEN = /^cmj_[A-Za-z0-9_-]{16,4096}$/
/** The join token outlives the pairing code's ten minutes only by the platform's own cap. */
const TTL_SECONDS = 600

const JOIN_TOKEN_ID = /^[A-Za-z0-9_-]{1,256}$/
export const machineJoinLive = (join: PairMachineJoin, now: number): boolean =>
  TOKEN.test(join.token) && JOIN_TOKEN_ID.test(join.join_token_id) && Number.isSafeInteger(join.expires_at) && join.expires_at > now

/** The platform's display label is 1 to 63 characters. */
const label = (name: string): string | undefined => {
  const trimmed = name.trim().slice(0, 63).trim()
  return trimmed ? trimmed : undefined
}

/**
 * Mints the box's join token for `user` in `team`. A deployment without the platform binding (local, tests), or whose
 * platform refuses (4xx), mints none and pairs as before; a platform that refuses or cannot be reached fails the approval before any install or
 * host is written, so a retry finishes it.
 */
export const mintPairMachineJoin = async (env: Pick<Env, "PLATFORM" | "INTERNAL_TOKEN">, input: { team: string; user: string; name: string }): Promise<Minted> => {
  if (!env.PLATFORM || !env.INTERNAL_TOKEN) return { ok: true, join: null }
  const unavailable = (message = "the machine credential could not be made, try again"): Minted => ({ ok: false, code: "owner.unreachable", message, retryable: true })
  let response: Response
  try {
    response = await env.PLATFORM.fetch("https://platform/internal/v1/machines/join-tokens", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${env.INTERNAL_TOKEN}` },
      body: JSON.stringify({ teamId: input.team, userId: input.user, ttlSeconds: TTL_SECONDS, ...(label(input.name) ? { label: label(input.name) } : {}) }),
      signal: AbortSignal.timeout(10_000)
    })
  } catch {
    return unavailable()
  }
  // A refusal (404: this deployment's platform runs no machine join, as on staging; 403: the platform's own role rule)
  // never costs the person the pairing: it goes on as before, without the join token. Only an outage is retried.
  if (response.status >= 400 && response.status < 500) {
    console.warn(JSON.stringify({ msg: "pair.machine_join.refused", status: response.status }))
    return { ok: true, join: null }
  }
  if (!response.ok) {
    console.warn(JSON.stringify({ msg: "pair.machine_join.mint_failed", status: response.status }))
    return unavailable()
  }
  let body: { token?: unknown; expiresAt?: unknown; joinTokenId?: unknown }
  try {
    body = (await response.json()) as typeof body
  } catch {
    return unavailable()
  }
  const expires = typeof body.expiresAt === "string" ? Date.parse(body.expiresAt) : Number.NaN
  const join = { token: typeof body.token === "string" ? body.token : "", expires_at: expires, join_token_id: typeof body.joinTokenId === "string" ? body.joinTokenId : "" }
  return machineJoinLive(join, Date.now()) ? { ok: true, join } : unavailable()
}
