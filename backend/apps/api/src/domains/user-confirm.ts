import { createHash } from "node:crypto"
import { user as homeUser } from "@cmux/home-core"
import type { ReduceContext, ReduceResult } from "@cmux/ownership"
import type { UserState } from "./user.ts"

/**
 * UserDO side of the per-user text confirmation level (home-messaging.md section 21): the
 * state lives in `UserState.confirm`, the logic is home-core `reduceUserConfirm`, and UserDO
 * supplies what only it knows (installs, the user's chiefs, the App Attest app id).
 */
export const USER_CONFIRM_OPS = homeUser.USER_CONFIRM_OPS

/** sha256("<Team ID>.<bundle id>") (base64url) from the IOS_APP_ID setting, or "" when unset (iOS lowering then fails closed). */
export const appIdHashFor = (iosAppId: string | undefined) => (iosAppId ? createHash("sha256").update(iosAppId).digest("base64url") : "")

export const confirmEnv = (state: UserState, appIdHash: string): homeUser.UserConfirmEnv => ({
  user: state.user?.id ?? "",
  installActive: (id) => state.installs[id]?.revoked_at === null,
  installKind: (id) => state.installs[id]?.kind,
  appIdHash,
  // Chief records are not in UserDO yet (chief.* reducers pending); no chief receives the level until then.
  chiefs: [],
  locale: "en"
})

export const reduceConfirm = (state: UserState, op: string, params: unknown, ctx: ReduceContext, appIdHash: string): ReduceResult<UserState> => {
  const r = homeUser.reduceUserConfirm(state.confirm ?? homeUser.EMPTY_USER_CONFIRM, op, (params ?? {}) as Record<string, unknown>, ctx, confirmEnv(state, appIdHash))
  if (!r.ok) return { ok: false, code: r.code, message: r.message }
  return { ok: true, state: { ...state, confirm: r.state }, value: r.value, ...(r.changed === false ? { changed: false } : {}), ...(r.outbox ? { outbox: [...r.outbox] } : {}) }
}

/** The presence key of a revoked install dies with it (install.revoke, sign-out, revoke_by_team). */
export const revokePresenceKey = (state: UserState, install: string, now: number): UserState => {
  const confirm = state.confirm
  const key = confirm?.presence_keys[install]
  if (!confirm || !key || key.revoked_at !== null) return state
  return {
    ...state,
    confirm: {
      ...confirm,
      presence_keys: { ...confirm.presence_keys, [install]: { ...key, revoked_at: now } },
      challenges: confirm.challenges.filter((c) => c.install !== install),
      audit: [...confirm.audit, { at: now, kind: "key_revoked" as const, by: "system:install.revoke", from: homeUser.userLevelOf(confirm), to: homeUser.userLevelOf(confirm), install }].slice(-homeUser.MAX_AUDIT)
    }
  }
}

/** user.text_confirm.get: what Settings shows; public key parts only. */
export const confirmView = (state: UserState) => {
  const c = state.confirm ?? homeUser.EMPTY_USER_CONFIRM
  return {
    level: homeUser.userLevelOf(c),
    own_level: c.level ?? "strict",
    locks: c.locks,
    rev: c.rev,
    presence_keys: Object.fromEntries(Object.entries(c.presence_keys).map(([install, k]) => [install, { platform: k.platform, registered_at: k.registered_at, usable_from: k.usable_from, revoked_at: k.revoked_at }]))
  }
}
