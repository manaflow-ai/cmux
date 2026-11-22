import { Cron } from "croner"

/**
 * Five-field cron in an IANA time zone (spec cloud-and-automations.md: cron
 * floor of one minute). Pure: the same (expr, tz, after) always gives the same
 * instant, so the SchedulerDO reducer stays deterministic.
 */

export type CronCheck = { ok: true } | { ok: false; message: string }

const validTimeZone = (tz: string) => {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: tz })
    return true
  } catch {
    return false
  }
}

const build = (expr: string, tz: string) => new Cron(expr, { timezone: tz, paused: true, mode: "5-part" })

export const checkCron = (expr: string, tz: string): CronCheck => {
  if (expr.trim().split(/\s+/).length !== 5) return { ok: false, message: "cron needs exactly 5 fields (minute hour day-of-month month day-of-week)" }
  if (!validTimeZone(tz)) return { ok: false, message: `unknown time zone ${tz}` }
  try {
    // An expression that never fires (for example 30 February) is useless and keeps no alarm.
    if (build(expr, tz).nextRun(new Date(0)) === null) return { ok: false, message: "cron never fires" }
    return { ok: true }
  } catch (e) {
    return { ok: false, message: e instanceof Error ? e.message : String(e) }
  }
}

/** The first scheduled instant strictly after `after` (ms), or null when it never fires again. */
export const nextFire = (expr: string, tz: string, after: number): number | null => {
  const next = build(expr, tz).nextRun(new Date(after))
  return next ? next.getTime() : null
}
