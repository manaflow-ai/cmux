import { parseRfc3339Millis } from "./ids.ts"
import type { RejectCode } from "./reject.ts"
import type { ConversationHead, Message, Part } from "./types.ts"
import { findParticipant, hasText } from "./validate.ts"

/**
 * The agent turn budget (home.md section 5, Rust `budget.rs`): agents may post
 * at most MAX_AGENT_TURNS text messages after the last human message, at least
 * MIN_AGENT_GAP_MS apart, so two agents cannot loop.
 */
export const MAX_AGENT_TURNS = 4
export const MIN_AGENT_GAP_MS = 2_000
/** How many of the newest messages the host must pass. */
export const BUDGET_WINDOW = MAX_AGENT_TURNS + 1

/**
 * Checks a `message.send` of `parts` by `actor`. `recent` holds the newest
 * messages, newest first (at least BUDGET_WINDOW when that many exist). Humans
 * are never limited; messages with no text (work cards) are neither limited
 * nor counted. Cloud: a head with `settings.agent_budget` uses its turns and
 * gap instead of the constants. Returns null when the send may proceed.
 */
export const checkAgentBudget = (
  head: ConversationHead,
  actor: string,
  parts: ReadonlyArray<Part>,
  recent: ReadonlyArray<Message>,
  nowMs: number
): RejectCode | null => {
  const isAgent = (id: string) => findParticipant(head, id)?.kind === "agent"
  if (!isAgent(actor) || !hasText(parts)) return null
  const maxTurns = head.settings?.agent_budget.turns ?? MAX_AGENT_TURNS
  const gapMs = head.settings?.agent_budget.gap_ms ?? MIN_AGENT_GAP_MS
  const turns = recent.filter((message) => hasText(message.parts))
  let agentTurns = 0
  for (const message of turns) {
    if (!isAgent(message.author)) break
    agentTurns++
  }
  if (agentTurns >= maxTurns) return "agent_budget"
  // A clock that moved back (now before the last agent message) never blocks.
  const lastAgent = turns.find((message) => isAgent(message.author))
  const at = lastAgent ? parseRfc3339Millis(lastAgent.created_at) : null
  if (at !== null && nowMs >= at && nowMs < at + gapMs) return "agent_rate"
  return null
}
