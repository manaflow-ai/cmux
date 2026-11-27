import type { RowReader } from "@cmux/ownership"
import { allAutomations } from "./scheduler-rows.ts"

/** Provider event matching for `event` triggers (SchedulerDO, integration events). Pure. */

/** Dot path lookup in a provider payload (filters compare the value as a string). */
const pathValue = (payload: unknown, path: string): unknown => {
  let v: unknown = payload
  for (const k of path.split(".")) {
    if (v === null || typeof v !== "object") return undefined
    v = (v as Record<string, unknown>)[k]
  }
  return v
}

/** Event triggers of enabled automations that match a provider event: same connection, event pattern, every filter. */
export const matchingEventTriggers = (
  rows: RowReader | undefined,
  ev: { connection: string; event: string; payload: unknown; sharing: "private" | "team"; created_by: string }
): Array<{ automation: string; trigger: string }> => {
  const out: Array<{ automation: string; trigger: string }> = []
  for (const a of allAutomations(rows)) {
    if (!a.enabled) continue
    // A private connection's events start only its creator's automations.
    if (ev.sharing !== "team" && a.created_by !== ev.created_by) continue
    for (const t of a.triggers) {
      const s = t.spec
      if (t.status !== "active" || s.type !== "event" || s.source !== "integration" || s.connection !== ev.connection) continue
      const pattern = s.event
      const eventOk = pattern === "*" || pattern === ev.event || (pattern.endsWith(".*") && ev.event.startsWith(pattern.slice(0, -1)))
      if (!eventOk) continue
      if (s.filter && !Object.entries(s.filter).every(([k, v]) => String(pathValue(ev.payload, k)) === v)) continue
      out.push({ automation: a.id, trigger: t.id })
    }
  }
  return out
}
