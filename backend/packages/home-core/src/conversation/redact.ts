/**
 * EngineOptions.redact for ConversationDO (row mode): invite token hashes and
 * accept proofs stay with the owner and never reach subscribers through
 * events, effects or snapshots. The owner keeps the full values. Gap: the
 * `invhash` table's row keys are token hashes, and the engine redacts row
 * values, not keys; until it can drop whole tables from effects, keep
 * `invhash` writes out of subscriber effects (PRIVATE_TABLES). `unread` (per-user counts) and
 * `consent` (who has written in a DM, consent.ts) are owner bookkeeping and stay private too.
 */
export const PRIVATE_TABLES: ReadonlyArray<string> = ["invhash", "unread", "consent"]

const without = (value: unknown, keys: ReadonlyArray<string>): unknown => {
  if (!value || typeof value !== "object" || Array.isArray(value)) return value
  return Object.fromEntries(Object.entries(value as Record<string, unknown>).filter(([k]) => !keys.includes(k)))
}

export const conversationRedact = {
  params: (op: string, params: unknown): unknown =>
    op === "invite.create" ? without(params, ["token_hash"]) : op === "invite.accept" ? without(params, ["proof"]) : params,
  state: (state: unknown): unknown => {
    if (!state || typeof state !== "object") return state
    const s = state as { invites?: ReadonlyArray<unknown> }
    return s.invites ? { ...s, invites: s.invites.map((i) => without(i, ["token_hash"])) } : state
  },
  row: (table: string, row: unknown): unknown => (table === "inv" ? without(row, ["token_hash"]) : table === "invhash" ? {} : row)
}
