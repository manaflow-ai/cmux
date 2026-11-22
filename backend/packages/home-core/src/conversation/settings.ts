import { fail } from "./reject.ts"
import type { AgentBudgetSettings, ConversationSettings, HistoryVisible, WakePolicy } from "./types.ts"

const WAKE_POLICIES: ReadonlyArray<WakePolicy> = ["auto", "mentions", "all"]
const HISTORY: ReadonlyArray<HistoryVisible> = ["all", "since_join"]
/** Bounds an owner may set: at least one agent turn, at most 16; a gap of at most 10 minutes. */
export const MAX_BUDGET_TURNS = 16
export const MAX_BUDGET_GAP_MS = 600_000

const validBudget = (budget: unknown): budget is AgentBudgetSettings => {
  if (typeof budget !== "object" || budget === null) return false
  const { turns, gap_ms } = budget as Record<string, unknown>
  return (
    Number.isInteger(turns) &&
    (turns as number) >= 1 &&
    (turns as number) <= MAX_BUDGET_TURNS &&
    Number.isInteger(gap_ms) &&
    (gap_ms as number) >= 0 &&
    (gap_ms as number) <= MAX_BUDGET_GAP_MS
  )
}

/**
 * Merges a settings patch into `current`. `requireField` refuses an empty
 * patch (`conversation.settings.set` must change something).
 */
export const validateSettings = (
  current: ConversationSettings,
  patch: Partial<Record<keyof ConversationSettings, unknown>>,
  requireField: boolean
): ConversationSettings => {
  const { wake_policy, agent_budget, history_visible } = patch
  if (requireField && wake_policy === undefined && agent_budget === undefined && history_visible === undefined) fail("invalid_settings")
  if (wake_policy !== undefined && !WAKE_POLICIES.includes(wake_policy as WakePolicy)) fail("invalid_settings")
  if (history_visible !== undefined && !HISTORY.includes(history_visible as HistoryVisible)) fail("invalid_settings")
  if (agent_budget !== undefined && !validBudget(agent_budget)) fail("invalid_settings")
  return {
    wake_policy: (wake_policy as WakePolicy | undefined) ?? current.wake_policy,
    agent_budget: agent_budget === undefined ? current.agent_budget : { turns: (agent_budget as AgentBudgetSettings).turns, gap_ms: (agent_budget as AgentBudgetSettings).gap_ms },
    history_visible: (history_visible as HistoryVisible | undefined) ?? current.history_visible
  }
}
