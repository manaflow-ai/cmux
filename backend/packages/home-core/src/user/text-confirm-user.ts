import type { OutboxItem, Principal, ReduceContext } from "../conversation/engine-types.ts"
import { effectiveLock, isLevel, isRiskier, safest, USER_APP_KINDS, type ConfirmLevel, type LevelLocks } from "../mux/confirm-level.ts"
import { LOWER_OP, verifyAppAttest, verifyPresence, p256Key, type AppAttestKey, type ProofPayload } from "./device-proof.ts"
import { securityNotice } from "./notices.ts"

/**
 * The text confirmation level, once per user (decision 2026-10-02), owned by
 * UserDO; every chief's MuxDO holds a projection (`mux.text_confirm.level.sync`).
 * Safer applies at once. Riskier ("lowering") needs a server-checked device
 * proof: a fresh single-use nonce from `user.text_confirm.lower.challenge`,
 * signed after Face ID or the device passcode by the install's presence key
 * (and, on iOS, an App Attest assertion). A team or MDM lock wins. Every
 * lowering and every new presence key is announced to all of the owner's
 * devices (feed) and by email. Pure: UserDO's domain delegates these ops.
 */
export const CHALLENGE_TTL_MS = 2 * 60_000
export const MAX_CHALLENGES = 5
/** A new presence key cannot authorize a lowering for this long (time to notice a key added by an intruder). */
export const NEW_KEY_COOLDOWN_MS = 24 * 3_600_000
export const MAX_AUDIT = 50

export interface PresenceKey {
  readonly jwk: unknown
  readonly platform: "mac" | "ios"
  /** iOS: the App Attest key the Worker verified at registration (Apple's attestation chain). */
  readonly app_attest?: AppAttestKey
  readonly registered_at: number
  readonly usable_from: number
  readonly revoked_at: number | null
}

export interface Challenge {
  readonly nonce: string
  readonly install: string
  readonly new_level: ConfirmLevel
  readonly expires_at: number
}

export interface UserLevelAudit {
  readonly at: number
  readonly kind: "set" | "lowered" | "lower_refused" | "lock" | "unlock" | "migrate" | "key_added" | "key_revoked"
  readonly by: string
  readonly from: ConfirmLevel
  readonly to: ConfirmLevel
  readonly install?: string
  readonly reason?: string
}

export interface UserConfirmState {
  /** null until set or migrated (reads as strict). */
  readonly level: ConfirmLevel | null
  readonly locks: LevelLocks
  /** Bumped on every change of the level in effect; chiefs keep the newest. */
  readonly rev: number
  readonly challenges: ReadonlyArray<Challenge>
  readonly presence_keys: Readonly<Record<string, PresenceKey>>
  readonly audit: ReadonlyArray<UserLevelAudit>
}

export const EMPTY_USER_CONFIRM: UserConfirmState = { level: null, locks: {}, rev: 0, challenges: [], presence_keys: {}, audit: [] }

export const userLevelOf = (s: UserConfirmState): ConfirmLevel => effectiveLock(s.locks)?.level ?? s.level ?? "strict"

/** What the host (UserDO) knows that this module does not own. */
export interface UserConfirmEnv {
  readonly user: string
  readonly installActive: (install: string) => boolean
  /** The user's chiefs (agent ids), which receive the level. */
  readonly chiefs: ReadonlyArray<string>
  /** Locale for the notices (from the user profile), default en. */
  readonly locale?: string
}

export const USER_CONFIRM_OPS = new Set([
  "user.text_confirm.level.set",
  "user.text_confirm.lower.challenge",
  LOWER_OP,
  "user.text_confirm.lock",
  "user.text_confirm.migrate",
  "user.presence_key.register",
  "user.presence_key.revoke"
])
const SYSTEM_ONLY = new Set(["user.text_confirm.lock", "user.text_confirm.migrate", "user.presence_key.register"])
const DEVICE_ONLY = new Set(["user.text_confirm.lower.challenge", LOWER_OP])

const userOf = (p: Principal) => (p.user ? (p.user.startsWith("user_") ? p.user : `user_${p.user}`) : null)
const isOwnerApp = (p: Principal, user: string) =>
  (p.kind === "session" || (p.kind === "install" && !p.agent && USER_APP_KINDS.has(p.install_kind ?? ""))) && userOf(p) === user
/** A device app install of the owner (mac or ios): the only callers that can hold a presence key. */
const isOwnerDevice = (p: Principal, user: string) =>
  p.kind === "install" && !p.agent && (p.install_kind === "mac" || p.install_kind === "ios") && userOf(p) === user && typeof p.install === "string"

export const authorizeUserConfirm = (op: string, p: Principal, env: UserConfirmEnv): boolean => {
  if (SYSTEM_ONLY.has(op)) return p.kind === "system"
  if (DEVICE_ONLY.has(op)) return isOwnerDevice(p, env.user)
  if (op === "user.presence_key.revoke") return p.kind === "system" || isOwnerApp(p, env.user)
  return isOwnerApp(p, env.user)
}

export type UserConfirmResult =
  | { readonly ok: true; readonly state: UserConfirmState; readonly value: unknown; readonly changed?: boolean; readonly outbox?: ReadonlyArray<OutboxItem> }
  | { readonly ok: false; readonly code: string; readonly message: string }

type Params = Readonly<Record<string, unknown>>
const str = (v: unknown, max = 256): v is string => typeof v === "string" && v.length > 0 && v.length <= max

export const reduceUserConfirm = (s: UserConfirmState, op: string, params: Params, ctx: ReduceContext, env: UserConfirmEnv): UserConfirmResult => {
  const refuse = (code: string): UserConfirmResult => ({ ok: false, code, message: code })
  const current = userLevelOf(s)
  const actor = ctx.principal.kind === "system" ? ctx.principal.identity : (userOf(ctx.principal) ?? "unknown")
  const audited = (st: UserConfirmState, row: UserLevelAudit): UserConfirmState => ({ ...st, audit: [...st.audit, row].slice(-MAX_AUDIT) })
  const live = s.challenges.filter((c) => c.expires_at > ctx.now)
  /** Commits `next`; when the level in effect changed, bumps rev and syncs every chief. */
  const commit = (next: UserConfirmState, value: unknown, extra: ReadonlyArray<OutboxItem> = []): UserConfirmResult => {
    const to = userLevelOf(next)
    if (to === current) return { ok: true, state: next, value, outbox: extra }
    const rev = s.rev + 1
    const sync: Array<OutboxItem> = env.chiefs.map((agent) => ({
      kind: "mux.text_confirm.level.sync",
      entity: `level:${env.user}:${rev}`,
      payload: { level: to, rev },
      target: { class: "MuxDO", name: agent, coalesce: "text_confirm_level" }
    }))
    return { ok: true, state: { ...next, rev }, value, outbox: [...sync, ...extra] }
  }
  switch (op) {
    case "user.text_confirm.level.set": {
      if (ctx.origin !== "user") return refuse("forbidden")
      const to = params.level
      if (!isLevel(to)) return refuse("invalid_params")
      const lock = effectiveLock(s.locks)
      if (lock) return to === lock.level ? { ok: true, state: s, value: { level: current }, changed: false } : refuse("text_confirm.locked")
      if (to === current) return { ok: true, state: s, value: { level: current }, changed: false }
      if (isRiskier(to, current)) return refuse("text_confirm.proof_required")
      return commit(audited({ ...s, level: to, challenges: [] }, { at: ctx.now, kind: "set", by: actor, from: current, to }), { level: to })
    }
    case "user.text_confirm.lower.challenge": {
      if (ctx.origin !== "user") return refuse("forbidden")
      const to = params.level
      const install = ctx.principal.install!
      if (!isLevel(to)) return refuse("invalid_params")
      if (effectiveLock(s.locks)) return refuse("text_confirm.locked")
      if (!isRiskier(to, current)) return refuse("text_confirm.not_lower")
      const key = s.presence_keys[install]
      if (!key || key.revoked_at !== null || !env.installActive(install)) return refuse("text_confirm.no_presence_key")
      if (ctx.now < key.usable_from) return refuse("text_confirm.key_cooling_down")
      const challenge: Challenge = { nonce: ctx.newId("nonce"), install, new_level: to, expires_at: ctx.now + CHALLENGE_TTL_MS }
      const payload: ProofPayload = { op: LOWER_OP, user: env.user, install, new_level: to, nonce: challenge.nonce, expires_at: challenge.expires_at }
      return { ok: true, state: { ...s, challenges: [...live.filter((c) => c.install !== install), challenge].slice(-MAX_CHALLENGES) }, value: { sign: payload } }
    }
    case LOWER_OP: {
      if (ctx.origin !== "user") return refuse("forbidden")
      const install = ctx.principal.install!
      const challenge = s.challenges.find((c) => c.nonce === params.nonce)
      if (!challenge) return refuse("text_confirm.bad_nonce")
      // Single use: the nonce is spent by any attempt, valid or not; the attempt is committed and audited.
      const spent = { ...s, challenges: s.challenges.filter((c) => c !== challenge) }
      const fail = (reason: string): UserConfirmResult => ({
        ok: true,
        state: audited(spent, { at: ctx.now, kind: "lower_refused", by: actor, from: current, to: challenge.new_level, install, reason }),
        value: { lowered: false, code: reason }
      })
      if (challenge.install !== install || params.level !== challenge.new_level) return fail("text_confirm.proof_mismatch")
      if (ctx.now >= challenge.expires_at) return fail("text_confirm.proof_expired")
      const key = s.presence_keys[install]
      if (!key || key.revoked_at !== null || !env.installActive(install) || ctx.now < key.usable_from) return fail("text_confirm.no_presence_key")
      if (effectiveLock(s.locks) || !isRiskier(challenge.new_level, current)) return fail("text_confirm.stale")
      const payload: ProofPayload = { op: LOWER_OP, user: env.user, install, new_level: challenge.new_level, nonce: challenge.nonce, expires_at: challenge.expires_at }
      if (!str(params.presence_sig, 512) || !verifyPresence(key.jwk, payload, params.presence_sig)) return fail("text_confirm.bad_proof")
      let keys = s.presence_keys
      if (key.platform === "ios") {
        if (!key.app_attest || !str(params.app_attest, 8192)) return fail("text_confirm.bad_proof")
        const attest = verifyAppAttest(key.app_attest, payload, params.app_attest)
        if (!attest.ok) return fail("text_confirm.bad_proof")
        keys = { ...keys, [install]: { ...key, app_attest: { ...key.app_attest, counter: attest.counter } } }
      }
      const to = challenge.new_level
      const next = audited({ ...spent, level: to, presence_keys: keys }, { at: ctx.now, kind: "lowered", by: actor, from: current, to, install })
      return commit(next, { lowered: true, level: to }, securityNotice(env, "lowered", s.rev + 1, { from: current, to, install, at: ctx.now }))
    }
    case "user.text_confirm.lock": {
      const { level, by, name } = params
      if (by !== "team_policy" && by !== "mdm") return refuse("invalid_params")
      if (level === null) {
        const prior = s.locks[by]
        if (!prior) return { ok: true, state: s, value: { level: current }, changed: false }
        const { [by]: _gone, ...rest } = s.locks
        // Unlock keeps the level in effect, so lifting one lock never lowers protection by itself.
        return commit(audited({ ...s, level: current, locks: rest }, { at: ctx.now, kind: "unlock", by: actor, from: current, to: current }), { level: current })
      }
      if (!isLevel(level) || typeof name !== "string" || name.length === 0 || name.length > 120) return refuse("invalid_params")
      const prior = s.locks[by]
      if (prior && prior.level === level && prior.name === name) return { ok: true, state: s, value: { level: current }, changed: false }
      const locks = { ...s.locks, [by]: { level, by, name, at: ctx.now } }
      const next = audited({ ...s, locks, challenges: [] }, { at: ctx.now, kind: "lock", by: actor, from: current, to: userLevelOf({ ...s, locks }) })
      return commit(next, { level: userLevelOf(next), lock: effectiveLock(locks) })
    }
    case "user.text_confirm.migrate": {
      // From each chief's former per-chief level: the result only ever gets safer.
      const { level } = params
      if (!isLevel(level)) return refuse("invalid_params")
      const to = s.level === null ? level : safest([s.level, level])!
      if (to === s.level) return { ok: true, state: s, value: { level: current }, changed: false }
      return commit(audited({ ...s, level: to }, { at: ctx.now, kind: "migrate", by: actor, from: current, to }), { level: to })
    }
    case "user.presence_key.register": {
      // Built by the Worker after it authenticated the install and (iOS) verified Apple's App Attest attestation.
      const { install, jwk, platform, app_attest } = params
      if (!str(install, 128) || (platform !== "mac" && platform !== "ios") || !p256Key(jwk)) return refuse("invalid_params")
      if (!env.installActive(install)) return refuse("forbidden")
      const attest = app_attest as AppAttestKey | undefined
      if (platform === "ios" && (!attest || !p256Key(attest.jwk) || !str(attest.app_id_hash, 64) || !Number.isSafeInteger(attest.counter))) return refuse("invalid_params")
      const key: PresenceKey = { jwk, platform, ...(platform === "ios" ? { app_attest: attest! } : {}), registered_at: ctx.now, usable_from: ctx.now + NEW_KEY_COOLDOWN_MS, revoked_at: null }
      const next = audited({ ...s, presence_keys: { ...s.presence_keys, [install]: key } }, { at: ctx.now, kind: "key_added", by: actor, from: current, to: current, install })
      return { ok: true, state: next, value: { install, usable_from: key.usable_from }, outbox: securityNotice(env, "key_added", ctx.now, { install, at: ctx.now }) }
    }
    case "user.presence_key.revoke": {
      const { install } = params
      if (!str(install, 128)) return refuse("invalid_params")
      const key = s.presence_keys[install]
      if (!key || key.revoked_at !== null) return { ok: true, state: s, value: null, changed: false }
      const next = { ...s, presence_keys: { ...s.presence_keys, [install]: { ...key, revoked_at: ctx.now } }, challenges: s.challenges.filter((c) => c.install !== install) }
      return { ok: true, state: audited(next, { at: ctx.now, kind: "key_revoked", by: actor, from: current, to: current, install }), value: null }
    }
    default:
      return refuse("invalid_params")
  }
}
