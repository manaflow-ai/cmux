import type { Env } from "../env.ts"
import type { Caller } from "./route.ts"

/**
 * The free tier (cx-dna4.3): an attested Apple device without a sign-in. Not built yet: no token
 * resolves to a free caller, so every request needs a signed-in team member.
 */
export const freeCaller = async (_env: Env, _token: string): Promise<Caller | undefined> => undefined

/** Refusal for a device over its quota, or undefined when it may proceed. */
export const freeAdmit = async (_env: Env, _device: string, _tokenBound: number): Promise<Response | undefined> =>
  Response.json({ error: { code: "free.disabled", message: "the free tier is off" } }, { status: 403 })

export const freeSettle = async (_env: Env, _device: string, _tokens: number): Promise<void> => {}
