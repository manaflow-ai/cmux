import { canonicalJson, type ReduceContext } from "@cmux/ownership"
import type { Automation, TriggerInput } from "@cmux/protocol"
import { checkCron, nextFire } from "../cron.ts"
import { reject } from "./common.ts"

/** Trigger validation and storage of the SchedulerDO reducer. Pure. */

/** Trigger types this backend fires today; the rest are stored for the UI and marked. */
export const SUPPORTED_TRIGGERS: ReadonlySet<TriggerInput["type"]> = new Set(["cron", "manual", "continue", "webhook"])

/** Whether this backend fires a trigger: the supported types, plus integration events bound to a connection. */
export const triggerSupported = (spec: TriggerInput) => SUPPORTED_TRIGGERS.has(spec.type) || (spec.type === "event" && spec.source === "integration" && spec.connection !== undefined)

export const validateTriggers = (triggers: ReadonlyArray<TriggerInput>) => {
  for (const t of triggers) {
    if (t.type === "cron") {
      const c = checkCron(t.expr, t.tz)
      if (!c.ok) return reject("trigger.invalid", c.message)
    }
    if (t.type === "presence" && t.earliest) {
      const c = checkCron(t.earliest.expr, t.earliest.tz)
      if (!c.ok) return reject("trigger.invalid", `presence earliest: ${c.message}`)
    }
  }
  if (triggers.filter((t) => t.type === "continue").length > 1) return reject("trigger.invalid", "at most one continue trigger")
  return undefined
}

/**
 * Stored triggers for a new list. A trigger whose spec is unchanged keeps its id
 * (webhook endpoints embed it) and its schedule; `rescheduleFrom` recomputes
 * every cron schedule (on enable, so slots missed while disabled do not fire).
 */
export const storeTriggers = (inputs: ReadonlyArray<TriggerInput>, previous: Automation["triggers"], ctx: ReduceContext, rescheduleFrom?: number): Automation["triggers"] => {
  const pool = [...previous]
  return inputs.map((spec) => {
    const key = canonicalJson(spec)
    const i = pool.findIndex((t) => canonicalJson(t.spec) === key)
    const kept = i >= 0 ? pool.splice(i, 1)[0] : undefined
    const status = triggerSupported(spec) ? ("active" as const) : ("not_yet_supported" as const)
    let next_at: number | null = kept?.next_at ?? null
    if (spec.type === "cron" && (!kept || rescheduleFrom !== undefined)) next_at = nextFire(spec.expr, spec.tz, rescheduleFrom ?? ctx.now)
    if (spec.type !== "cron" && spec.type !== "continue") next_at = null
    // Re-enabling never resumes a continue chain stopped by disabling; the next run starts one.
    if (spec.type === "continue" && rescheduleFrom !== undefined) next_at = null
    return { id: kept?.id ?? ctx.newId("trg"), status, spec, next_at }
  })
}
