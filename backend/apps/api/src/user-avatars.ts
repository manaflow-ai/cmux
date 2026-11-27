import type { Principal } from "@cmux/ownership"
import { admit } from "./domains/common.ts"
import { chiefActive, grantFor, userPathAllowed, type UserState } from "./domains/user.ts"
import type { Env } from "./env.ts"
import { AvatarRefs, avatarKey, avatarsConfigured, checkAvatar, mayAvatarSet, toBase64, type AvatarRef } from "./home-avatars.ts"

/**
 * The UserDO side of participant avatars (home-avatars.ts): its one RPC, `UserDO.avatar(call)`,
 * runs here with the object's storage, bucket and current state.
 */
export type AvatarCall =
  | { readonly op: "set"; readonly entity: string; readonly principal: Principal; readonly participant: string; readonly data: Uint8Array | null }
  | { readonly op: "get"; readonly entity: string; readonly participant: string }
export type AvatarAnswer = { ok: true; avatar: AvatarRef | (AvatarRef & { data: string }) | null } | { ok: false; code: string; message: string }

export const avatarRpc = async (ctx: DurableObjectState, env: Env, state: UserState | undefined, call: AvatarCall): Promise<AvatarAnswer> => {
  if (!state || state.user?.id !== call.entity) return { ok: false, code: "unknown_participant", message: "unknown user" }
  const refs = new AvatarRefs(ctx.storage.sql)
  return call.op === "get" ? avatarGet(env, refs, call.entity, call.participant) : avatarSet(ctx, env, refs, state, call.entity, call.principal, call.participant, call.data)
}

/**
 * participant.avatar.set for a participant of this account (the user or one of its Chiefs). One at
 * a time: the blob is written before its reference, and a blob is deleted only after the reference
 * that named it is gone and no other participant of the account names it.
 */
const avatarSet = async (ctx: DurableObjectState, env: Env, refs: AvatarRefs, state: UserState, entity: string, principal: Principal, participant: string, data: Uint8Array | null): Promise<AvatarAnswer> => {
  // The same admission as every account op: the principal kind, a live install and its grant.
  if (!userPathAllowed(state, principal)) return { ok: false, code: "auth.forbidden", message: "install revoked or unknown" }
  const denied = admit("cloud:UserDO", "participant.avatar.set", principal, (p) => grantFor(state, p), Date.now())
  if (denied) return { ok: false, code: denied.code, message: denied.message }
  const refused = mayAvatarSet(entity, principal, participant, (id) => chiefActive(state, id))
  if (refused) return refused
  if (!avatarsConfigured(env)) return { ok: false, code: "home.not_configured", message: "avatars are not configured on this deployment" }
  let ref: AvatarRef | null = null
  if (data) {
    const checked = checkAvatar(data)
    if ("ok" in checked) return checked
    ref = checked.ref
  }
  const bucket = env.HOME_ATTACHMENTS!
  const result = await ctx.blockConcurrencyWhile(async () => {
    // The blob first, then its reference: a failed write changes nothing.
    if (ref && data) {
      try {
        await bucket.put(avatarKey(entity, ref.sha256), data, { httpMetadata: { contentType: ref.media_type } })
      } catch (error) {
        return { ok: false as const, code: "owner.unreachable", message: `the picture could not be stored: ${String(error)}` }
      }
    }
    const gone = [...refs.put(participant, ref)]
    // References of Chiefs that are gone for good (tombstones, or no record) go too.
    for (const stale of refs.participants().filter((id) => id.startsWith("agent_") && !state.chiefs?.[id])) gone.push(...refs.put(stale, null))
    return { ok: true as const, avatar: ref, gone }
  })
  if (!result.ok) return result
  // Unreferenced blobs: best effort (a failed delete leaves bytes nothing names).
  for (const sha of new Set(result.gone)) await bucket.delete(avatarKey(entity, sha)).catch(() => undefined)
  return { ok: true, avatar: result.avatar }
}

/** participant.avatar.get: the reference and the bytes (base64), or null. */
const avatarGet = async (env: Env, refs: AvatarRefs, entity: string, participant: string): Promise<AvatarAnswer> => {
  const ref = refs.get(participant)
  if (!ref || !env.HOME_ATTACHMENTS) return { ok: true, avatar: null }
  const object = await env.HOME_ATTACHMENTS.get(avatarKey(entity, ref.sha256))
  if (!object) return { ok: true, avatar: null }
  return { ok: true, avatar: { ...ref, data: toBase64(new Uint8Array(await object.arrayBuffer())) } }
}
