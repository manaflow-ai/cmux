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
interface AvatarConversationStub {
  sharesWith(entity: string, principal: Principal, participant: string): Promise<boolean>
}
const PARTICIPANT = /^(user|agent)_[A-Za-z0-9_.-]{1,64}$/
const CONVERSATION = /^conv_(dm_)?[0-9A-HJKMNP-TV-Z]{26}$/

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

/**
 * participant.avatar.get: the read's value, why the params are invalid, or `hidden`. The participant
 * reads their own and an owner its Chief's; anyone else names a conversation both are in (the
 * caller must be able to read it). Any other read is hidden, the same answer as an unknown participant.
 */
export const avatarGetRoute = async (env: Env, principal: Principal, params: unknown): Promise<{ invalid: string } | { hidden: true } | { value: { participant_id: string; avatar: unknown } }> => {
  const p = (params ?? {}) as { participant_id?: unknown; conversation?: unknown }
  const participant = p.participant_id
  if (typeof participant !== "string" || !PARTICIPANT.test(participant)) return { invalid: "participant.avatar.get needs a participant_id" }
  if (p.conversation !== undefined && (typeof p.conversation !== "string" || !CONVERSATION.test(p.conversation))) return { invalid: "conversation is a conversation id" }
  const owner = participant.startsWith("user_")
    ? participant
    : await (env.MUX_DO.get(env.MUX_DO.idFromName(participant)) as unknown as AvatarMuxStub).ownerOf(participant)
  const self = principal.user !== undefined && principal.user === owner && (participant === owner || principal.agent === undefined || principal.agent === participant)
  if (!self && !(typeof p.conversation === "string" && (await shared(env, principal, p.conversation, participant)))) return { hidden: true }
  if (!owner) return { value: { participant_id: participant, avatar: null } }
  const r = await userStub(env, owner).avatar({ op: "get", entity: owner, participant })
  return { value: { participant_id: participant, avatar: r.ok ? r.avatar : null } }
}

/** Whether `principal` may read `conversation` and `participant` is in it (not left). */
const shared = async (env: Env, principal: Principal, conversation: string, participant: string): Promise<boolean> => {
  const stub = env.CONVERSATION_DO.get(env.CONVERSATION_DO.idFromName(conversation)) as unknown as AvatarConversationStub
  // A large group's head is a roster: the conversation checks its member rows (home-core large.ts).
  return stub.sharesWith(conversation, principal, participant)
}
