import { parseRfc3339Millis } from "./ids.ts"
import type { RejectCode } from "./reject.ts"
import type { ConversationHead, Message, Part } from "./types.ts"
import { findParticipant, hasText } from "./validate.ts"

/**
 * The agent turn budget (home.md section 5, Rust `budget.rs`): in one thread
 * (the replies of one root, or the conversation's top level) agents may post at
 * most MAX_AGENT_TURNS text messages after the last person's text message in
 * that thread, and agent text messages are at least MIN_AGENT_GAP_MS apart in
 * the conversation, so agents (Chiefs) cannot loop. Agents in two threads do
 * not spend each other's budget; only a person's text resets one.
 *
 * The first round after a person's text is free of the gap: while a thread's
 * streak is below the number of agents in the conversation, every Chief may
 * answer the person at once (a group with two Chiefs answers in parallel, not
 * one gap apart). From the round's end on, agent texts are spaced again, so an
 * agent-to-agent exchange still waits the gap and stops at the turn budget.
 */
export const MAX_AGENT_TURNS = 6
export const MIN_AGENT_GAP_MS = 2_000
/** How many of the newest messages the host must pass. */
export const BUDGET_WINDOW = MAX_AGENT_TURNS + 1

/** The agents in the conversation now (left ones excluded): how many answers the gap lets through after a person's text. */
export const agentCount = (head: ConversationHead): number => head.participants.filter((p) => p.kind === "agent" && p.left_at === undefined).length

/** Whether an agent text at streak `streak` waits the gap: only once every agent may have answered the person. */
const gapApplies = (head: ConversationHead, streak: number): boolean => streak >= agentCount(head)

/** Whether `message` is in thread `threadRoot` (undefined: the top level). */
export const inThread = (message: Message, threadRoot: string | undefined): boolean => message.thread_root === threadRoot

/**
 * The agent text streak of thread `threadRoot` from rows: agent text messages
 * at the end of that thread, after its last person's text. `messages` newest
 * first; other threads' messages are skipped. The same count the head keeps
 * (`streakOf`), for a host or a page that holds messages, not the head ("Chiefs
 * paused" when it is at the budget).
 */
export const threadAgentStreak = (head: ConversationHead, messages: ReadonlyArray<Message>, threadRoot: string | undefined): number => {
  let count = 0
  for (const message of messages) {
    if (!inThread(message, threadRoot) || !hasText(message.parts)) continue
    const kind = findParticipant(head, message.author)?.kind
    // Only a person's text ends the streak; an author who left is skipped
    // (the head counted it at send time, so a row count only falls short).
    if (kind === "human") break
    if (kind === "agent") count++
  }
  return count
}

/** The head's agent text streak of thread `threadRoot` (undefined: the top level). */
export const streakOf = (head: ConversationHead, threadRoot: string | undefined): number =>
  threadRoot === undefined ? (head.agent_text_streak ?? 0) : (head.thread_agent_streaks?.[threadRoot] ?? 0)

/**
 * The head after one text turn in thread `threadRoot`: an agent's adds 1 to
 * that thread's streak and sets `last_agent_text_at`; a person's resets that
 * thread's streak only. A thread streak at 0 is dropped from the map, and an
 * empty map is absent, so the head stays small.
 */
export const withTurn = <H extends ConversationHead>(head: H, threadRoot: string | undefined, agent: boolean, now: string, seed?: number): H => {
  const value = agent ? (seed ?? streakOf(head, threadRoot)) + 1 : 0
  const timed = agent ? { last_agent_text_at: now } : {}
  if (threadRoot === undefined) return { ...head, agent_text_streak: value, ...timed }
  const map: Record<string, number> = { ...head.thread_agent_streaks }
  if (value === 0) delete map[threadRoot]
  else map[threadRoot] = value
  const keys = Object.keys(map).sort()
  const { thread_agent_streaks: _old, ...rest } = head
  return { ...(rest as H), ...timed, ...(keys.length === 0 ? {} : { thread_agent_streaks: Object.fromEntries(keys.map((k) => [k, map[k]!])) }) }
}

/**
 * Checks a `message.send` of `parts` by `actor` into thread `threadRoot`
 * (undefined: the top level). `recent` holds the newest messages, newest first
 * (at least BUDGET_WINDOW of that thread when that many exist). Humans are
 * never limited; messages with no text (work cards) are neither limited nor
 * counted. Cloud: a head with `settings.agent_budget` uses its turns and gap
 * instead of the constants. Returns null when the send may proceed.
 */
export const checkAgentBudget = (
  head: ConversationHead,
  actor: string,
  parts: ReadonlyArray<Part>,
  recent: ReadonlyArray<Message>,
  nowMs: number,
  threadRoot?: string
): RejectCode | null => {
  const isAgent = (id: string) => findParticipant(head, id)?.kind === "agent"
  if (!isAgent(actor) || !hasText(parts)) return null
  const maxTurns = head.settings?.agent_budget.turns ?? MAX_AGENT_TURNS
  const gapMs = head.settings?.agent_budget.gap_ms ?? MIN_AGENT_GAP_MS
  const streak = threadAgentStreak(head, recent, threadRoot)
  if (streak >= maxTurns) return "agent_budget"
  if (!gapApplies(head, streak)) return null
  const turns = recent.filter((message) => hasText(message.parts))
  // A clock that moved back (now before the last agent message) never blocks.
  const lastAgent = turns.find((message) => isAgent(message.author))
  const at = lastAgent ? parseRfc3339Millis(lastAgent.created_at) : null
  if (at !== null && nowMs >= at && nowMs < at + gapMs) return "agent_rate"
  return null
}

/**
 * The loop guard, O(1) and without a row window: reads the head's streak of
 * thread `threadRoot` (`agent_text_streak` for the top level,
 * `thread_agent_streaks` for a thread) and `last_agent_text_at` (kept by
 * `apply` on every send). Same limits (and the same free first round) as `checkAgentBudget`; differences from
 * the row-window check: a retracted agent message still counts, and the gap
 * applies to the last agent text message however old.
 */
export const checkAgentStreak = (head: ConversationHead, actor: string, parts: ReadonlyArray<Part>, nowMs: number, threadRoot?: string): RejectCode | null => {
  if (findParticipant(head, actor)?.kind !== "agent" || !hasText(parts)) return null
  const maxTurns = head.settings?.agent_budget.turns ?? MAX_AGENT_TURNS
  const gapMs = head.settings?.agent_budget.gap_ms ?? MIN_AGENT_GAP_MS
  const streak = streakOf(head, threadRoot)
  if (streak >= maxTurns) return "agent_budget"
  if (!gapApplies(head, streak)) return null
  const at = head.last_agent_text_at === undefined ? null : parseRfc3339Millis(head.last_agent_text_at)
  if (at !== null && nowMs >= at && nowMs < at + gapMs) return "agent_rate"
  return null
}
