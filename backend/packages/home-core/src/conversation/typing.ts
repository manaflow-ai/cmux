/**
 * Typing indicators (home-messaging.md sections 3 and 20 row 7): never stored, never in the
 * ledger, never projected. The owner keeps one memo per participant in memory and broadcasts a
 * frame only when this gate allows it:
 *
 * - `on` repeated within TYPING_REFRESH_MS of the last broadcast `on` is dropped (clients expire
 *   an indicator that is not refreshed, so a refresh after the interval passes);
 * - at most TYPING_MAX_ON `on` broadcasts per participant per TYPING_WINDOW_MS;
 * - `off` passes only when the last broadcast was `on`, so it is bounded by the `on` cap and a
 *   receiver never keeps a stale indicator because an `off` was dropped.
 *
 * Pure, so every owner (ConversationDO, the self-hosted owner) applies the same limits.
 */
export const TYPING_REFRESH_MS = 3_000
export const TYPING_WINDOW_MS = 10_000
export const TYPING_MAX_ON = 5

export interface TypingMemo {
  /** The last broadcast state. */
  readonly on: boolean
  readonly at: number
  /** Times of the `on` broadcasts inside the window. */
  readonly ons: ReadonlyArray<number>
}

export interface TypingDecision {
  readonly send: boolean
  readonly memo: TypingMemo | undefined
}

export const typingGate = (memo: TypingMemo | undefined, on: boolean, now: number): TypingDecision => {
  if (!on) return memo?.on ? { send: true, memo: { ...memo, on: false, at: now } } : { send: false, memo }
  if (memo?.on && now - memo.at < TYPING_REFRESH_MS) return { send: false, memo }
  const ons = (memo?.ons ?? []).filter((at) => now - at < TYPING_WINDOW_MS)
  if (ons.length >= TYPING_MAX_ON) return { send: false, memo: memo ? { ...memo, ons } : memo }
  return { send: true, memo: { on: true, at: now, ons: [...ons, now] } }
}
