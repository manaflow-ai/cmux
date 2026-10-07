import type { ReduceContext, ReduceResult } from "@cmux/ownership"
import { NotifyActivityEnd, NotifyActivityRegister, PushPrefsSet, type ActivityTarget, type PushPrefs, type PushTarget } from "@cmux/protocol"
import { decodeParams, reject } from "./common.ts"
import type { PushTargetsState } from "./user-push.ts"

/**
 * The notify slice of UserDO (plans/cmux-next/ios-next/c7-notify.md): each
 * iOS install's push preferences and its Live Activity push tokens. Absent in
 * objects created before it.
 */
export interface NotifyState extends PushTargetsState {
  readonly push_prefs?: Readonly<Record<string, PushPrefs>>
  readonly activities?: Readonly<Record<string, ActivityTarget>>
}

/** ActivityKit keeps an Activity at most 8 h active plus 4 h on the lock screen. */
export const ACTIVITY_TTL_MS = 12 * 3600_000
export const MAX_ACTIVITIES_PER_INSTALL = 16
export const MAX_ACTIVITIES_PER_USER = 32

export const NOTIFY_OPS: ReadonlySet<string> = new Set(["push.prefs.set", "notify.activity.register", "notify.activity.end"])

const iosInstall = (s: NotifyState, ctx: ReduceContext) => {
  const p = ctx.principal
  if (p.kind !== "install" || !p.install) return reject("auth.forbidden", "only a device install sets this")
  if (s.installs[p.install]?.kind !== "ios") return reject("auth.forbidden", "only an iOS install sets this")
  if (s.installs[p.install]?.revoked_at !== null) return reject("auth.forbidden", "install revoked")
  return p.install
}

const live = (s: NotifyState, now: number) => (a: ActivityTarget) => s.installs[a.install]?.revoked_at === null && now - a.registered_at < ACTIVITY_TTL_MS

export const reduceNotify = <S extends NotifyState>(state: S, op: string, params: unknown, ctx: ReduceContext): ReduceResult<S> => {
  if (op === "push.prefs.set") {
    const d = decodeParams<typeof PushPrefsSet.params.Type>(PushPrefsSet, params)
    if (!d.ok) return d
    const install = iosInstall(state, ctx)
    if (typeof install !== "string") return install
    const prefs: PushPrefs = { kinds: [...new Set(d.value.kinds)].sort(), sound: d.value.sound, time_sensitive: d.value.time_sensitive }
    const prior = state.push_prefs?.[install]
    if (prior && JSON.stringify(prior) === JSON.stringify(prefs)) return { ok: true, state, value: prefs, changed: false }
    return { ok: true, state: { ...state, push_prefs: { ...state.push_prefs, [install]: prefs } }, value: prefs }
  }
  if (op === "notify.activity.register") {
    const d = decodeParams<typeof NotifyActivityRegister.params.Type>(NotifyActivityRegister, params)
    if (!d.ok) return d
    const install = iosInstall(state, ctx)
    if (typeof install !== "string") return install
    const v = d.value
    const all = state.activities ?? {}
    const prior = all[v.activity]
    if (prior && prior.install !== install) return reject("auth.forbidden", "this activity belongs to another install")
    const target: ActivityTarget = {
      activity: v.activity,
      install,
      push_token: v.push_token,
      subject: v.subject,
      title: v.title ?? prior?.title ?? "",
      started_at: v.started_at ?? prior?.started_at ?? ctx.now,
      registered_at: ctx.now
    }
    // Expired and revoked registrations go; then the oldest beyond the caps.
    const kept = Object.values(all).filter((a) => a.activity !== v.activity && live(state, ctx.now)(a)).sort((a, b) => a.registered_at - b.registered_at)
    const mine = kept.filter((a) => a.install === install)
    const dropMine = new Set(mine.slice(0, Math.max(0, mine.length - (MAX_ACTIVITIES_PER_INSTALL - 1))).map((a) => a.activity))
    const rest = kept.filter((a) => !dropMine.has(a.activity))
    const room = rest.slice(Math.max(0, rest.length - (MAX_ACTIVITIES_PER_USER - 1)))
    return { ok: true, state: { ...state, activities: Object.fromEntries([...room, target].map((a) => [a.activity, a])) }, value: target }
  }
  if (op === "notify.activity.end") {
    const d = decodeParams<typeof NotifyActivityEnd.params.Type>(NotifyActivityEnd, params)
    if (!d.ok) return d
    const prior = state.activities?.[d.value.activity]
    if (!prior) return { ok: true, state, value: { activity: d.value.activity, ended: false }, changed: false }
    const p = ctx.principal
    if (p.kind !== "session" && p.install !== prior.install) return reject("auth.forbidden", "an install ends only its own activity")
    const { [d.value.activity]: _, ...rest } = state.activities ?? {}
    return { ok: true, state: { ...state, activities: rest }, value: { activity: d.value.activity, ended: true } }
  }
  return reject("validation.invalid", `unknown op ${op}`)
}

/** A revoked install keeps no preferences or activities (with its push targets, user.ts revokeInstall). */
export const dropInstallNotify = <S extends NotifyState>(state: S, install: string): S => {
  const { [install]: _, ...prefs } = state.push_prefs ?? {}
  const activities = Object.fromEntries(Object.entries(state.activities ?? {}).filter(([, a]) => a.install !== install))
  return { ...state, ...(state.push_prefs ? { push_prefs: prefs } : {}), ...(state.activities ? { activities } : {}) }
}

/** A push target with its install's preferences (none: every kind, sound, time-sensitive). */
export interface NotifyPushTarget extends PushTarget {
  readonly prefs?: PushPrefs
}

/** A live activity with where to send it: its install's APNs topic and environment. */
export interface NotifyActivityTarget extends ActivityTarget {
  readonly topic: string
  readonly environment: PushTarget["environment"]
}

export interface NotifyTargets {
  readonly push: ReadonlyArray<NotifyPushTarget>
  readonly activities: ReadonlyArray<NotifyActivityTarget>
}

/** For FeedDO and Home push (UserDO.notifyTargets): live targets with prefs, and live activities with a push target. */
export const notifyTargetsOf = (state: NotifyState | undefined, now: number): NotifyTargets => {
  if (!state) return { push: [], activities: [] }
  const push = Object.values(state.push_targets ?? {})
    .filter((t) => state.installs[t.install]?.revoked_at === null)
    .map((t): NotifyPushTarget => (state.push_prefs?.[t.install] ? { ...t, prefs: state.push_prefs[t.install]! } : t))
  const byInstall = new Map(push.map((t) => [t.install, t]))
  const activities = Object.values(state.activities ?? {})
    .filter(live(state, now))
    .flatMap((a): Array<NotifyActivityTarget> => {
      const t = byInstall.get(a.install)
      return t ? [{ ...a, topic: t.topic, environment: t.environment }] : []
    })
  return { push, activities }
}
