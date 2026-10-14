import type { AiUsageData, AiUsageMember } from "./-ai-usage-view"

/**
 * Sample states of the AI usage view for the preview route (preview.ai-usage.tsx). Public-safe made-up
 * data: no real people, teams or ids.
 */
const DAY = 86_400_000
const now = Date.UTC(2026, 9, 14)
const monthEnd = Date.UTC(2026, 10, 1)

const member = (user: string, display_name: string, role: string, spent_usd: number, limit_usd = 200, source: AiUsageMember["source"] = "default"): AiUsageMember => ({ user, display_name, role, spent_usd, limit_usd, source })

const crew: ReadonlyArray<AiUsageMember> = [
  member("u_1", "Ada Park", "owner", 8.4),
  member("u_2", "Ben Ito", "admin", 3.15, 50, "personal"),
  member("u_3", "Chen Wu", "member", 0.62),
  member("u_4", "Dana Rossi", "member", 0, 0, "personal")
]

const base = { default_usd: 200, is_default: true, resets_at: monthEnd, members: crew } satisfies Omit<AiUsageData, "team_usage">

export const AI_USAGE_STATES: Readonly<Record<string, { readonly note: string; readonly data: AiUsageData }>> = {
  "billed-team": {
    note: "Pro, billable: 12.17 of 20 USD included this billing period.",
    data: { ...base, team_usage: { billed: true, included_usd: 20, per_seat: false, seats: 1, spent_usd: 12.17, period_start: now - 10 * DAY, period_end: now + 20 * DAY, stop_applies: false, stopped: false } }
  },
  "billed-over": {
    note: "Team per seat, 3 seats: 74.30 used against 60 included, 14.30 billed at cost.",
    data: { ...base, default_usd: 100, is_default: false, team_usage: { billed: true, included_usd: 60, per_seat: true, seats: 3, spent_usd: 74.3, period_start: now - 25 * DAY, period_end: now + 5 * DAY, stop_applies: false, stopped: false }, members: [member("u_1", "Ada Park", "owner", 41.2, 100, "team"), member("u_2", "Ben Ito", "admin", 33.1, 100, "team"), member("u_5", "Eli Novak", "billing", 0, 100, "team")] }
  },
  "unbilled-near": {
    note: "Founders (no card): 17.40 of 20 included this month; the stop is near.",
    data: { ...base, team_usage: { billed: false, included_usd: 20, per_seat: false, seats: 1, spent_usd: 17.4, period_start: Date.UTC(2026, 9, 1), period_end: monthEnd, stop_applies: true, stopped: false } }
  },
  "unbilled-open": {
    note: "No card, the stop off (development default): 23.10 used against 20 included; nothing pauses.",
    data: { ...base, team_usage: { billed: false, included_usd: 20, per_seat: false, seats: 1, spent_usd: 23.1, period_start: Date.UTC(2026, 9, 1), period_end: monthEnd, stop_applies: false, stopped: false } }
  },
  stopped: {
    note: "App Store plan: the included amount is used up; AI is paused until the reset.",
    data: { ...base, team_usage: { billed: false, included_usd: 20, per_seat: false, seats: 1, spent_usd: 20, period_start: Date.UTC(2026, 9, 1), period_end: monthEnd, stop_applies: true, stopped: true }, members: [member("u_1", "Ada Park", "owner", 20, 200)] }
  },
  "no-line": {
    note: "Plan not known yet: limits only.",
    data: { ...base }
  }
}
export const AI_USAGE_STATE_NAMES = Object.keys(AI_USAGE_STATES)
