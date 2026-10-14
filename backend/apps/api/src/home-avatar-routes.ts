import type { Principal } from "@cmux/ownership"
import type { Env } from "./env.ts"
import { fromBase64 } from "./home-avatars.ts"
import type { AvatarAnswer, AvatarCall } from "./user-avatars.ts"

/**
 * Worker side of participant avatars (home-avatars.ts). The bytes go to R2 through the account's
 * UserDO, outside its op ledger; a read goes to the account that keeps the picture (a person's
 * own, a Chief's owner's, found through the Chief's MuxDO).
 */
interface AvatarUserStub {
  avatar(call: AvatarCall): Promise<AvatarAnswer>
}
interface AvatarMuxStub {
  ownerOf(agent: string): Promise<string | null>
}
const userStub = (env: Env, user: string) => env.USER_DO.get(env.USER_DO.idFromName(user)) as unknown as AvatarUserStub
const PARTICIPANT = /^(user|agent)_[A-Za-z0-9_.-]{1,64}$/

/** participant.avatar.set: the /v1/ops result shape (a refusal is `ok: false` with an error). */
export const avatarSetRoute = async (env: Env, principal: Principal, frame: { readonly op: string; readonly params: unknown; readonly idempotency_key: string }) => {
  const params = (frame.params ?? {}) as { participant_id?: unknown; bytes?: unknown; clear?: unknown }
  const reply = (r: AvatarAnswer) => {
    const base = { op: frame.op, transaction: "", idempotency_key: frame.idempotency_key, replayed: false, stream: `user:${principal.user}`, sequence: 0 }
    return r.ok
      ? { ok: true, ...base, value: { participant_id: params.participant_id, avatar: r.avatar } }
      : { ok: false, ...base, error: { code: r.code, message: r.message, retryable: false } }
  }
  if (typeof params.participant_id !== "string" || (params.clear === true) === (typeof params.bytes === "string")) {
    return reply({ ok: false, code: "validation.invalid", message: "give participant_id and bytes (base64), or clear: true" })
  }
  const data = typeof params.bytes === "string" ? fromBase64(params.bytes) : null
  if (typeof params.bytes === "string" && !data) return reply({ ok: false, code: "avatar_invalid", message: "bytes must be base64" })
  if (!principal.user) return reply({ ok: false, code: "forbidden", message: "an avatar is set by a signed-in person" })
  return reply(await userStub(env, principal.user).avatar({ op: "set", entity: principal.user, principal, participant: params.participant_id, data }))
}

/** participant.avatar.get: the read's value, or why the params are invalid. */
export const avatarGetRoute = async (env: Env, params: unknown): Promise<{ invalid: string } | { value: { participant_id: string; avatar: unknown } }> => {
  const participant = (params as { participant_id?: unknown } | null)?.participant_id
  if (typeof participant !== "string" || !PARTICIPANT.test(participant)) return { invalid: "participant.avatar.get needs a participant_id" }
  const owner = participant.startsWith("user_")
    ? participant
    : await (env.MUX_DO.get(env.MUX_DO.idFromName(participant)) as unknown as AvatarMuxStub).ownerOf(participant)
  if (!owner) return { value: { participant_id: participant, avatar: null } }
  const r = await userStub(env, owner).avatar({ op: "get", entity: owner, participant })
  return { value: { participant_id: participant, avatar: r.ok ? r.avatar : null } }
}
