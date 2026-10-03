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
const FINISHED: ReadonlySet<string> = new Set(["succeeded", "failed", "cancelled", "skipped", "dead"])

export const isAutomationPrincipal = (p: Principal) => p.kind === "agent" && typeof p.run === "string" && p.identity.startsWith("automation:")

/** Runs one tree (a root run and everything automations started below it) may start (review P1). */
export const MAX_TREE_RUNS = 25

/**
 * The trigger of a run an automation starts, and the tree counters to store, or the refusal.
 * The tree budget holds even if capabilities leak between concurrent runs of one automation:
 * any run reached that way still belongs to a tree, and every tree is capped.
 */
export const automationTrigger = (
  state: SchedulerState,
  p: Principal,
  target: Automation
): { trigger: Run["trigger"]; trees: Record<string, number> } | ({ ok: false } & Reject) => {
  if (target.body.type === "agent_prompt") return { ok: false, code: "auth.forbidden", message: "an automation cannot start an agent_prompt automation" }
  const parent = state.runs[p.run!]
  // The caller is running, so its record exists; an unknown caller is refused (fail closed).
  if (!parent || parent.automation !== p.agent) return { ok: false, code: "auth.forbidden", message: "the calling run is unknown" }
  if (FINISHED.has(parent.state)) return { ok: false, code: "auth.forbidden", message: "the calling run has finished" }
  const chained = parent.trigger.type === "automation"
  const depth = (chained ? (parent.trigger.depth ?? MAX_AUTOMATION_DEPTH) : 0) + 1
  if (depth > MAX_AUTOMATION_DEPTH) return { ok: false, code: "automation.depth", message: `automations may start runs at most ${MAX_AUTOMATION_DEPTH} levels deep` }
  const root = chained ? parent.trigger.root_run : parent.id
  if (!root) return { ok: false, code: "automation.fanout", message: "the calling run's chain predates run trees; it may not start runs" }
  // Keep counters only for trees that still have a run in state (bounded by the runs kept).
  const live = new Set<string>()
  for (const r of Object.values(state.runs)) {
    live.add(r.id)
    if (r.trigger.root_run) live.add(r.trigger.root_run)
  }
  const trees: Record<string, number> = {}
  for (const [k, v] of Object.entries(state.automation_trees ?? {})) if (live.has(k)) trees[k] = v
  const used = trees[root] ?? 0
  if (used >= MAX_TREE_RUNS) return { ok: false, code: "automation.fanout", message: `one run and the runs it starts may start at most ${MAX_TREE_RUNS} runs` }
  trees[root] = used + 1
  return { trigger: { id: null, type: "automation", parent_run: parent.id, root_run: root, depth }, trees }
}
