import type { Principal } from "@cmux/ownership"
import type { Env } from "./env.ts"

/** The `/v1/ops` reply the pairing routes build (pair-routes.ts, pair-invite-routes.ts). */
export type OpReply = {
  ok: boolean
  op: string
  value?: unknown
  error?: { code: string; message: string; retryable: boolean }
  transaction: string
  idempotency_key: string
  replayed: boolean
  stream: string
  sequence: number
}

export const fail = (op: string, key: string, code: string, message: string, retryable = false): OpReply => ({
  ok: false,
  op,
  error: { code, message, retryable },
  transaction: "",
  idempotency_key: key,
  replayed: false,
  stream: "",
  sequence: 0
})

/** A user-origin session only: never an install token, never an agent acting through one. */
export const isHumanSession = (p: Principal) => p.kind === "session" && !p.agent && Boolean(p.user)

/**
 * Per-user limits on the pairing namespace (user keys). `user` bounds preview,
 * approve and invite (code guessing, invite minting); `user-retry` is spent only after `user` refused,
 * by an approve that may be a retry of the caller's own claim, so a retry is
 * never blocked by the guessing budget and PairingDO wakes stay bounded.
 */
export const pairLimited = async (env: Env, principal: Principal, bucket: "user" | "user-retry" = "user"): Promise<boolean> => {
  if (!env.PAIR_BEGIN_LIMIT) return true
  const { success } = await env.PAIR_BEGIN_LIMIT.limit({ key: `${bucket}:${principal.user}` })
  return success
}

export const pairingStub = (env: Env, code: string) => env.PAIRING_DO.get(env.PAIRING_DO.idFromName(code))
