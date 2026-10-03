import { conversationDomain } from "../src/conversation/domain.ts"
import type { Principal } from "../src/conversation/engine-types.ts"
import type { ConversationHead } from "../src/conversation/types.ts"
import { MemoryRows } from "../test/support/harness.ts"

/**
 * Corpus for `conversation.import` / `conversation.import.commit` (cloud only;
 * the Rust owner is the source side and never runs these): each case is
 * {name, before, principal, op, params, now, expect: {state, value} | {reject}},
 * replayed in order on one ConversationDO with MemoryRows.
 */
export interface ImportCase {
  readonly name: string
  readonly principal: Principal
  readonly op: string
  readonly params: unknown
  readonly now: number
  readonly expect: { readonly ok: true; readonly head: unknown; readonly value: unknown; readonly writes: number } | { readonly ok: false; readonly reject: string }
}

const NOW = 1_790_000_000_000
const ME: Principal = { identity: "user:user_me", kind: "session", user: "user_me" }
const OTHER: Principal = { identity: "user:user_x", kind: "session", user: "user_x" }
const AT = (s: number) => new Date(NOW - 3_600_000 + s * 1000).toISOString()
const msg = (seq: number, author: string, text: string, extra: Record<string, unknown> = {}) => ({ id: `msg_local${seq}`, seq, client_msg_id: `c${seq}`, author, parts: [{ type: "text", text }], created_at: AT(seq), ...extra })
const people = [
  { id: "user_me", kind: "human", display_name: "Me" },
  { id: "agent_chief", kind: "agent", display_name: "Chief", agent_class: "mux", owner_user: "user_me" }
]
const source = { kind: "mac", host: "inst_mac1", local_id: "conv_LOCAL1" }

export const importCases = (): Array<ImportCase> => {
  let state: ConversationHead | null = null
  const rows = new MemoryRows()
  let n = 0
  const out: Array<ImportCase> = []
  const run = (name: string, principal: Principal, op: string, params: Record<string, unknown>) => {
    const r = conversationDomain.reduce(state, op, params, { principal, now: NOW, tx: `t${++n}`, newId: (p) => `${p}_${n}`, rows, origin: "user" })
    if (r.ok) {
      state = r.state
      rows.apply(r.writes ?? [])
      out.push({ name, principal, op, params, now: NOW, expect: { ok: true, head: JSON.parse(JSON.stringify(r.state)), value: JSON.parse(JSON.stringify(r.value)), writes: (r.writes ?? []).length } })
    } else out.push({ name, principal, op, params, now: NOW, expect: { ok: false, reject: r.code } })
  }
  run("import: a stranger as participant is refused", ME, "conversation.import", { id: "conv_P1", source, kind: "chief", participants: [...people, { id: "user_x", kind: "human", display_name: "X" }], messages: [] })
  run("import: an agent the importer does not own is refused", ME, "conversation.import", { id: "conv_P1", source, kind: "chief", participants: [people[0], { ...people[1], owner_user: "user_x" }], messages: [] })
  run("import: a gap in seq is refused", ME, "conversation.import", { id: "conv_P1", source, kind: "chief", participants: people, messages: [msg(2, "user_me", "hi")] })
  run("import: an author outside the participants is refused", ME, "conversation.import", { id: "conv_P1", source, kind: "chief", participants: people, messages: [msg(1, "agent_other", "hi")] })
  run("import: the first batch creates the head in importing", ME, "conversation.import", {
    id: "conv_P1", source, kind: "chief", title: "Chief", participants: people, read_cursors: { user_me: 3 },
    messages: [msg(1, "user_me", "start"), msg(2, "agent_chief", "on it", { edited_at: AT(10), reactions: [{ author: "user_me", part_index: 0, kind: { tapback: "like" }, at: AT(11) }] }), msg(3, "agent_chief", "", { parts: [], retracted_at: AT(12) })]
  })
  run("import: a repeated create with the same source is a no-op", ME, "conversation.import", { id: "conv_P1", source, kind: "chief", participants: people, messages: [] })
  run("import: a create with another source is conversation_exists", ME, "conversation.import", { id: "conv_P1", source: { ...source, local_id: "conv_OTHER" }, kind: "chief", participants: people, messages: [] })
  run("import: normal ops wait for commit", ME, "message.send", { client_msg_id: "k1", parts: [{ type: "text", text: "early" }] })
  run("import: another user cannot continue", OTHER, "conversation.import", { id: "conv_P1", after_seq: 3, messages: [msg(4, "user_me", "x")] })
  run("import: a batch out of order is refused", ME, "conversation.import", { id: "conv_P1", after_seq: 2, messages: [msg(3, "user_me", "x")] })
  run("import: a duplicate client_msg_id per author is refused", ME, "conversation.import", { id: "conv_P1", after_seq: 3, messages: [{ ...msg(4, "user_me", "dup"), client_msg_id: "c1" }] })
  run("import: the next batch continues the seq and the agent streak", ME, "conversation.import", { id: "conv_P1", after_seq: 3, messages: [msg(4, "agent_chief", "more"), msg(5, "agent_chief", "and more")] })
  run("import: commit with the wrong last_seq is refused", ME, "conversation.import.commit", { id: "conv_P1", last_seq: 4 })
  run("import: commit opens the conversation and bumps the inbox", ME, "conversation.import.commit", { id: "conv_P1", last_seq: 5 })
  run("import: a batch after commit is conversation_exists", ME, "conversation.import", { id: "conv_P1", after_seq: 5, messages: [msg(6, "user_me", "x")] })
  run("import: normal ops run after commit", ME, "message.send", { client_msg_id: "k2", parts: [{ type: "text", text: "now" }] })
  return out
}
