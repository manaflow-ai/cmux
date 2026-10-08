import { makeConversationDomain } from "../src/conversation/domain.ts"
import { importConversationId } from "../src/conversation/ids.ts"
import type { ParticipantPolicy } from "../src/conversation/policy.ts"
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
const ID = importConversationId("user_me", source.host, source.local_id)
/** The DO's reach policy for the corpus: user_me owns agent_chief (the real one reads UserDO's chief records). */
const OWNED: Record<string, string> = { agent_chief: "user_me", agent_helper: "user_me", agent_victim: "user_victim" }
const policy: ParticipantPolicy = (principal, p) =>
  p.kind === "human"
    ? { ok: true, display_name: principal.display_name ?? "Me" }
    : p.kind === "agent" && OWNED[p.id]
      ? { ok: true, owner_user: OWNED[p.id], display_name: p.display_name }
      : { ok: false, code: "forbidden" }
const domain = makeConversationDomain({ participantPolicy: policy })

export const importCases = (): Array<ImportCase> => {
  let state: ConversationHead | null = null
  const rows = new MemoryRows()
  let n = 0
  const out: Array<ImportCase> = []
  const run = (name: string, principal: Principal, op: string, params: Record<string, unknown>) => {
    const r = domain.reduce(state, op, params, { principal, now: NOW, tx: `t${++n}`, newId: (p) => `${p}_${n}`, rows, origin: "user" })
    if (r.ok) {
      state = r.state
      rows.apply(r.writes ?? [])
      out.push({ name, principal, op, params, now: NOW, expect: { ok: true, head: JSON.parse(JSON.stringify(r.state)), value: JSON.parse(JSON.stringify(r.value)), writes: (r.writes ?? []).length } })
    } else out.push({ name, principal, op, params, now: NOW, expect: { ok: false, reject: r.code } })
  }
  run("import: an id not derived from the importer and source is refused", ME, "conversation.import", { id: "conv_00000000000000000000000000", source, kind: "chief", participants: people, messages: [] })
  run("import: an agent the policy says belongs to another user is refused even if the params claim it", ME, "conversation.import", { id: ID, source, kind: "group", participants: [people[0], { id: "agent_victim", kind: "agent", display_name: "V", agent_class: "mux", owner_user: "user_me" }], messages: [] })
  run("import: a chief conversation must be the owner and one mux agent", ME, "conversation.import", { id: ID, source, kind: "chief", participants: [...people, { id: "agent_helper", kind: "agent", display_name: "H", agent_class: "agent" }], messages: [] })
  run("import: times may not go backwards", ME, "conversation.import", { id: ID, source, kind: "chief", participants: people, messages: [msg(1, "user_me", "a"), { ...msg(2, "user_me", "b"), created_at: AT(0) }] })
  run("import: a reply must point to an earlier message", ME, "conversation.import", { id: ID, source, kind: "chief", participants: people, messages: [{ ...msg(1, "user_me", "a"), reply_to: { message_id: "msg_local2", part_index: 0 } }, msg(2, "user_me", "b")] })
  run("import: a batch above 1 MiB is refused", ME, "conversation.import", { id: ID, source, kind: "chief", participants: people, messages: [msg(1, "user_me", "x".repeat(60_000)), ...Array.from({ length: 20 }, (_, i) => msg(i + 2, "user_me", "y".repeat(60_000)))] })
  run("import: a stranger as participant is refused", ME, "conversation.import", { id: ID, source, kind: "chief", participants: [...people, { id: "user_x", kind: "human", display_name: "X" }], messages: [] })
  run("import: an agent unknown to the reach policy is refused", ME, "conversation.import", { id: ID, source, kind: "chief", participants: [people[0], { ...people[1], id: "agent_unknown" }], messages: [] })
  run("import: a gap in seq is refused", ME, "conversation.import", { id: ID, source, kind: "chief", participants: people, messages: [msg(2, "user_me", "hi")] })
  run("import: an author outside the participants is refused", ME, "conversation.import", { id: ID, source, kind: "chief", participants: people, messages: [msg(1, "agent_other", "hi")] })
  run("import: the first batch creates the head in importing", ME, "conversation.import", {
    id: ID, source, kind: "chief", title: "Chief", participants: people, read_cursors: { user_me: 3 },
    messages: [msg(1, "user_me", "start"), msg(2, "agent_chief", "on it", { edited_at: AT(10), reactions: [{ author: "user_me", part_index: 0, kind: { tapback: "like" }, at: AT(11) }] }), msg(3, "agent_chief", "", { parts: [], retracted_at: AT(12), reply_to: undefined })]
  })
  run("import: a repeated create with the same source is a no-op", ME, "conversation.import", { id: ID, source, kind: "chief", participants: people, messages: [] })
  run("import: a create with another source is conversation_exists", ME, "conversation.import", { id: ID, source: { ...source, local_id: "conv_OTHER" }, kind: "chief", participants: people, messages: [] })
  run("import: normal ops wait for commit", ME, "message.send", { client_msg_id: "k1", parts: [{ type: "text", text: "early" }] })
  run("import: another user cannot continue", OTHER, "conversation.import", { id: ID, after_seq: 3, messages: [msg(4, "user_me", "x")] })
  run("import: a batch out of order is refused", ME, "conversation.import", { id: ID, after_seq: 2, messages: [msg(3, "user_me", "x")] })
  run("import: a duplicate client_msg_id per author is refused", ME, "conversation.import", { id: ID, after_seq: 3, messages: [{ ...msg(4, "user_me", "dup"), client_msg_id: "c1" }] })
  run("import: the next batch continues the seq and the agent streak", ME, "conversation.import", { id: ID, after_seq: 3, messages: [msg(4, "agent_chief", "more"), msg(5, "agent_chief", "and more")] })
  run("import: commit with the wrong last_seq is refused", ME, "conversation.import.commit", { id: ID, last_seq: 4 })
  run("import: commit opens the conversation and bumps the inbox", ME, "conversation.import.commit", { id: ID, last_seq: 5 })
  run("import: a batch after commit is conversation_exists", ME, "conversation.import", { id: ID, after_seq: 5, messages: [msg(6, "user_me", "x")] })
  run("import: normal ops run after commit", ME, "message.send", { client_msg_id: "k2", parts: [{ type: "text", text: "now" }] })
  // Shared with the Rust local import (cmux-tui-core conversation_import.rs replays this case's
  // messages): only text or question messages are agent turns, an imported work card is not.
  state = null
  run("import: an imported agent work card is not an agent turn", ME, "conversation.import", {
    id: importConversationId("user_me", source.host, "conv_LOCAL2"), source: { ...source, local_id: "conv_LOCAL2" }, kind: "chief", participants: people,
    messages: [
      msg(1, "user_me", "go", { id: "msg_wc1", client_msg_id: "wc1" }),
      msg(2, "agent_chief", "on it", { id: "msg_wc2", client_msg_id: "wc2" }),
      msg(3, "agent_chief", "", { id: "msg_wc3", client_msg_id: "wc3", parts: [{ type: "work", session: "s1", status: "running" }] }),
      msg(4, "agent_chief", "done", { id: "msg_wc4", client_msg_id: "wc4" })
    ]
  })
  return out
}
