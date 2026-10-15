import type { Env } from "./env.ts"
import { handName, indexName } from "./hand-index.ts"
import { randomB32, sha256Hex, type HandCaller, type HandReply, type HandSummary, type Profile } from "./hand-wire.ts"

/**
 * Server-side hand operations, shared by the HTTP routes (a person) and the Chief brain's `hands`
 * and `agent` tools (a Chief). The caller is built in server code, never taken from a request body.
 */

export const handStub = (env: Env, hand: string) => env.HAND_DO.get(env.HAND_DO.idFromName(handName(hand)))
export const indexStub = (env: Env, user: string) => env.HAND_DO.get(env.HAND_DO.idFromName(indexName(user)))

/** The API origin hands dial (the deployment's public origin; set per environment). */
export const apiOrigin = (env: Env, request?: Request): string => env.CLOUD_API_ORIGIN ?? (request ? new URL(request.url).origin : "https://cloud-api.cmux.dev")

/** The one line a target machine runs to install and pair a hand. */
export const installLine = (origin: string, code: string, profile: Profile = "sandbox") =>
  `curl -fsSL ${origin}/hand/install.sh | sh -s -- --pair ${code}${profile === "mac" ? " --profile mac --root <folder>" : ""}`

export interface Minted {
  readonly hand: string
  readonly code: string
  readonly expires_at: number
  readonly install: string
}

/**
 * A single-use pairing code (10 minutes) for a new hand of `owner`. The owner mints any; a Chief
 * mints only with the `hands` grant. The code is `<hand id>.<secret>`; only the secret's hash is kept.
 */
export const mintPairCode = async (env: Env, caller: HandCaller, name: string, origin: string, profile: Profile = "sandbox"): Promise<HandReply<Minted>> => {
  if (caller.kind === "chief" && !(await indexStub(env, caller.user).listGrants()).includes(caller.agent ?? "")) {
    return { ok: false, error: { code: "hand.no_grant", message: "this Chief has no hands grant; the person grants it" } }
  }
  const hand = `hand_${randomB32(20)}`
  const secret = randomB32(24)
  const code = `${hand}.${secret}`
  const { expires_at } = await handStub(env, hand).mint(hand, caller.user, caller.kind === "owner" ? `session:${caller.user}` : `agent:${caller.agent}`, await sha256Hex(secret), name.slice(0, 80) || "hand")
  return { ok: true, value: { hand, code, expires_at, install: installLine(origin, code, profile) } }
}

/** Hands of the owner a caller may use (a Chief sees them only with the grant). */
export const listHands = async (env: Env, caller: HandCaller): Promise<HandReply<Array<HandSummary>>> => {
  const index = indexStub(env, caller.user)
  if (caller.kind === "chief" && !(await index.listGrants()).includes(caller.agent ?? "")) {
    return { ok: false, error: { code: "hand.no_grant", message: "this Chief has no hands grant; the person grants it" } }
  }
  return { ok: true, value: (await index.listHands()).filter((h) => h.paired_at !== null && h.revoked_at === null) }
}

/** A hand by id or by its name among the caller's hands. */
export const resolveHand = async (env: Env, caller: HandCaller, wanted: string): Promise<HandReply<string>> => {
  const w = wanted.trim()
  const listed = await listHands(env, caller)
  if (!listed.ok) return listed
  const byId = listed.value.find((h) => h.hand === w)
  if (byId) return { ok: true, value: byId.hand }
  const named = listed.value.filter((h) => h.name === w)
  if (named.length === 1) return { ok: true, value: named[0]!.hand }
  return { ok: false, error: { code: "hand.not_found", message: named.length === 0 ? `no hand is named ${w}` : `more than one hand is named ${w}; use its id` } }
}
