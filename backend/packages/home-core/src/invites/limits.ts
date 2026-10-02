/**
 * Invite rate limits as pure functions over stored timestamps
 * (home-messaging.md section 9). The inviter's UserDO keeps `InviterWindow`,
 * the recipient's ContactDO keeps `ContactWindow`; both persist what these
 * functions return. Times are Unix milliseconds from the host.
 */
export const HOUR = 3_600_000
export const DAY = 24 * HOUR

export interface InviterPolicy {
  readonly perDay: number
  readonly perWeek: number
  /** Limits for accounts younger than `newAccountAge` or without a verified email. */
  readonly newAccountPerDay: number
  readonly newAccountAge: number
}

export const DEFAULT_INVITER_POLICY: InviterPolicy = { perDay: 20, perWeek: 60, newAccountPerDay: 5, newAccountAge: DAY }

export interface ContactPolicy {
  /** One send per inviter per this period; a repeat joins the pending invite. */
  readonly perInviterPeriod: number
  /** At most this many distinct inviters per `distinctPeriod`. */
  readonly distinctInviters: number
  readonly distinctPeriod: number
}

export const DEFAULT_CONTACT_POLICY: ContactPolicy = { perInviterPeriod: 7 * DAY, distinctInviters: 3, distinctPeriod: 30 * DAY }

export interface InviterWindow {
  /** Send times in the last week, oldest first. */
  readonly sent: ReadonlyArray<number>
}

export interface InviterStanding {
  readonly accountCreatedAt: number
  readonly emailVerified: boolean
  /** Team admin override of the daily limit (TeamDO policy); null for none. */
  readonly perDayOverride?: number | null
  readonly reported?: boolean
}

export type Refusal =
  | { readonly ok: false; readonly code: "invite.rate_limited"; readonly retry_at: number; readonly scope: "inviter_day" | "inviter_week" }
  | { readonly ok: false; readonly code: "invite.blocked"; readonly scope: "inviter_reported" }

export type InviterDecision = { readonly ok: true; readonly window: InviterWindow } | Refusal

const prune = (times: ReadonlyArray<number>, since: number) => times.filter((t) => t > since)

/** Whether a sender is trusted with custom invite text (variant A). */
export const isTrustedInviter = (standing: InviterStanding, now: number, policy = DEFAULT_INVITER_POLICY): boolean =>
  standing.emailVerified && !standing.reported && now - standing.accountCreatedAt >= policy.newAccountAge

/** Takes one invite from the inviter's windows, or refuses with the time it frees up. */
export const takeInviterQuota = (
  window: InviterWindow,
  standing: InviterStanding,
  now: number,
  policy = DEFAULT_INVITER_POLICY
): InviterDecision => {
  if (standing.reported) return { ok: false, code: "invite.blocked", scope: "inviter_reported" }
  const week = prune(window.sent, now - 7 * DAY)
  const day = week.filter((t) => t > now - DAY)
  const trusted = isTrustedInviter(standing, now, policy)
  const perDay = standing.perDayOverride ?? (trusted ? policy.perDay : policy.newAccountPerDay)
  if (day.length >= perDay) return { ok: false, code: "invite.rate_limited", retry_at: day[day.length - perDay]! + DAY, scope: "inviter_day" }
  const perWeek = Math.max(policy.perWeek, perDay)
  if (week.length >= perWeek) return { ok: false, code: "invite.rate_limited", retry_at: week[week.length - perWeek]! + 7 * DAY, scope: "inviter_week" }
  return { ok: true, window: { sent: [...week, now] } }
}

export interface ContactWindow {
  /** Last send time per inviter user id. */
  readonly lastByInviter: Readonly<Record<string, number>>
}

export type ContactDecision =
  | { readonly ok: true; readonly send: true; readonly window: ContactWindow }
  /** A repeat inside the per-inviter period: attach to the pending invite, send nothing. */
  | { readonly ok: true; readonly send: false; readonly reason: "repeat"; readonly window: ContactWindow }
  | { readonly ok: false; readonly code: "invite.recipient_limited"; readonly retry_at: number }

/**
 * Per-recipient limits. The refusal is internal: the inviter sees the same
 * answer as for a sent invite, so recipient limits and suppression never leak.
 */
export const takeContactQuota = (window: ContactWindow, inviter: string, now: number, policy = DEFAULT_CONTACT_POLICY): ContactDecision => {
  const recent = Object.fromEntries(Object.entries(window.lastByInviter).filter(([, t]) => t > now - policy.distinctPeriod))
  const last = recent[inviter]
  if (last !== undefined && now - last < policy.perInviterPeriod) return { ok: true, send: false, reason: "repeat", window: { lastByInviter: recent } }
  const others = Object.entries(recent).filter(([who]) => who !== inviter)
  if (others.length >= policy.distinctInviters) {
    const oldest = Math.min(...others.map(([, t]) => t))
    return { ok: false, code: "invite.recipient_limited", retry_at: oldest + policy.distinctPeriod }
  }
  return { ok: true, send: true, window: { lastByInviter: { ...recent, [inviter]: now } } }
}

export interface AcceptLock {
  /** Failed `invite.accept` times in the last hour. */
  readonly failures: ReadonlyArray<number>
}

export const ACCEPT_FAILURES_PER_HOUR = 10

/** Secret guessing: after 10 failures in an hour the conversation refuses accepts for an hour. */
export const acceptLocked = (lock: AcceptLock, now: number): boolean => prune(lock.failures, now - HOUR).length >= ACCEPT_FAILURES_PER_HOUR

export const recordAcceptFailure = (lock: AcceptLock, now: number): AcceptLock => ({ failures: [...prune(lock.failures, now - HOUR), now] })
