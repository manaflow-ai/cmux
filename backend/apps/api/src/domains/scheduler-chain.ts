import type { Principal, Reject } from "@cmux/ownership"
import type { Automation, Run } from "@cmux/protocol"
import type { SchedulerState } from "./scheduler.ts"

/**
 * Runs started by automations (env.cmux.op and the op step, automation-caps.ts). Review P1:
 * without a bound, an automation that runs itself (or a cycle of automations) never stops,
 * and a manual-looking trigger would also reset continue chains. Such a run records its parent
 * run and a depth; depth past MAX_AUTOMATION_DEPTH is refused, and an automation may never
 * start an agent_prompt body (more power than its own classes).
 */
export const MAX_AUTOMATION_DEPTH = 3

export const isAutomationPrincipal = (p: Principal) => p.kind === "agent" && typeof p.run === "string" && p.identity.startsWith("automation:")

/** The trigger of a run an automation starts, or the refusal. */
export const automationTrigger = (state: SchedulerState, p: Principal, target: Automation): { trigger: Run["trigger"] } | ({ ok: false } & Reject) => {
  if (target.body.type === "agent_prompt") return { ok: false, code: "auth.forbidden", message: "an automation cannot start an agent_prompt automation" }
  const parent = state.runs[p.run!]
  // The caller is running, so its record exists; an unknown caller is refused (fail closed).
  if (!parent || parent.automation !== p.agent) return { ok: false, code: "auth.forbidden", message: "the calling run is unknown" }
  const depth = (parent.trigger.type === "automation" ? (parent.trigger.depth ?? MAX_AUTOMATION_DEPTH) : 0) + 1
  if (depth > MAX_AUTOMATION_DEPTH) return { ok: false, code: "automation.depth", message: `automations may start runs at most ${MAX_AUTOMATION_DEPTH} levels deep` }
  return { trigger: { id: null, type: "automation", parent_run: parent.id, depth } }
}
