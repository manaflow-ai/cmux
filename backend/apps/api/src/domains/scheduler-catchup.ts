import { nextFire } from "../cron.ts"

/**
 * The catch-up policy of a cron fire (docs/automations-teleport-teams.md section 3). A fire is
 * late when its slot is more than GRACE_MS before now (an alarm that ran late, an object that was
 * evicted, a teleport that carried an old last slot). Pure: the same inputs plan the same fire.
 */
export type CatchUp = "latest" | "all" | "none"

/** Alarm latency that still counts as on time. */
export const GRACE_MS = 60_000
/** `latest` fires the newest missed slot only when it is younger than this. */
export const LATEST_MAX_AGE_MS = 24 * 3600_000
/** `all` fires at most this many missed slots. */
export const ALL_MAX = 10
/** Bound on the slots one plan walks (a minute cron missed for a week is about 10,000). */
const WALK_MAX = 20_000

export interface FirePlan {
  /** The slot to run now, or null (nothing runs). */
  readonly run: number | null
  /** Slots that will never run, recorded as one skipped `run.missed` run when more than 0. */
  readonly missed: number
  /** The trigger's next slot after this fire. */
  readonly next_at: number | null
  /** The newest slot this fire accounts for (run or missed). */
  readonly last_slot: number
}

export const planFire = (expr: string, tz: string, scheduledAt: number, now: number, policy: CatchUp = "latest"): FirePlan => {
  if (now - scheduledAt <= GRACE_MS) return { run: scheduledAt, missed: 0, next_at: nextFire(expr, tz, Math.max(scheduledAt, now)), last_slot: scheduledAt }
  // Every slot from this one to now, oldest first.
  const due: Array<number> = [scheduledAt]
  for (let t = nextFire(expr, tz, scheduledAt); t !== null && t <= now && due.length < WALK_MAX; t = nextFire(expr, tz, t)) due.push(t)
  const newest = due.at(-1)!
  const afterNow = nextFire(expr, tz, now)
  if (policy === "none") return { run: null, missed: due.length, next_at: afterNow, last_slot: newest }
  if (policy === "latest") {
    if (now - newest > LATEST_MAX_AGE_MS) return { run: null, missed: due.length, next_at: afterNow, last_slot: newest }
    return { run: newest, missed: due.length - 1, next_at: afterNow, last_slot: newest }
  }
  // all: the oldest of the newest ALL_MAX slots runs now; the next wake runs the one after it.
  const dropped = Math.max(0, due.length - ALL_MAX)
  const run = due[dropped]!
  const following = due[dropped + 1] ?? afterNow
  return { run, missed: dropped, next_at: following, last_slot: run }
}
