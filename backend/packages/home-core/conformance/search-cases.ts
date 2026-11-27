import { create } from "../src/conversation/create.ts"
import { searchConversations, type SearchInput, type SearchSource } from "../src/conversation/search.ts"
import type { ConversationHead, Message, Part } from "../src/conversation/types.ts"

/**
 * Corpus for `conversation-search` (and the cloud `home.search` read): each
 * case is {name, actor, input, sources, expect: {hits} | {reject}}. The local
 * owner runs it with its SQLite messages; the expected order and snippets are
 * exact.
 */
export interface SearchCase {
  readonly name: string
  readonly actor: string
  readonly input: SearchInput
  readonly sources: ReadonlyArray<SearchSource>
  readonly expect: { readonly hits: unknown } | { readonly reject: string }
}

const NOW = "2026-10-02T12:00:00.000Z"
const at = (s: number) => `2026-10-02T12:00:${String(s).padStart(2, "0")}.000Z`
const human = (id: string) => ({ id, kind: "human" as const, display_name: id.slice(5) })
const agent = (id: string) => ({ id, kind: "agent" as const, display_name: "Chief", agent_class: "mux" as const })

const head = (id: string, title: string, participants: ReadonlyArray<ReturnType<typeof human> | ReturnType<typeof agent>>): ConversationHead => {
  const r = create({ id, actor: participants[0]!.id, title, participants, now: NOW })
  if (!r.ok) throw new Error(r.code)
  return r.head
}
const msg = (conversation: string, seq: number, author: string, second: number, parts: ReadonlyArray<Part>, extra: Partial<Message> = {}): Message => ({
  id: `msg_${conversation.slice(-4)}${String(seq).padStart(22, "0")}`,
  conversation,
  seq,
  client_msg_id: `c${seq}`,
  author,
  parts: [...parts],
  created_at: at(second),
  reactions: [],
  ...extra
})
const text = (t: string): Part => ({ type: "text", text: t })

export const searchCases = (): Array<SearchCase> => {
  const A = "user_alice"
  const B = "user_bob"
  const work = head("conv_WORK", "Launch", [human(A), agent("agent_mux")])
  const dm = head("conv_DMAB", "Bob", [human(A), human(B)])
  const other = head("conv_OTHR", "Private", [human(B), agent("agent_mux")])
  const long = `${"word ".repeat(40)}the deploy failed on ship-ios ${"tail ".repeat(40)}`.trim()
  const sources: ReadonlyArray<SearchSource> = [
    { head: work, messages: [
      msg("conv_WORK", 1, A, 1, [text("Can you fix the Deploy?")]),
      msg("conv_WORK", 2, "agent_mux", 3, [{ type: "work", session: "deploy", status: "running" }, text("deploy started")]),
      msg("conv_WORK", 3, "agent_mux", 5, [text(long)]),
      msg("conv_WORK", 4, A, 7, [], { retracted_at: at(8) })
    ] },
    { head: dm, messages: [msg("conv_DMAB", 1, B, 4, [text("ÉCOLE deploy notes")]), msg("conv_DMAB", 2, A, 6, [text("日本語のデプロイ deploy")])] },
    { head: other, messages: [msg("conv_OTHR", 1, B, 9, [text("secret deploy plan")])] }
  ]
  const run = (name: string, actor: string, input: SearchInput, src: ReadonlyArray<SearchSource> = sources): SearchCase => {
    const r = searchConversations(actor, input, src)
    return { name, actor, input, sources: src, expect: r.ok ? { hits: r.hits } : { reject: r.code } }
  }
  return [
    run("search: newest first across the actor's conversations only", A, { query: "deploy", limit: 100 }),
    run("search: the limit keeps the newest", A, { query: "deploy", limit: 2 }),
    run("search: case-insensitive for accented capitals", A, { query: "école", limit: 10 }),
    run("search: CJK substring", A, { query: "デプロイ", limit: 10 }),
    run("search: a long message gets a centered snippet with ellipses", A, { query: "ship-ios", limit: 10 }),
    run("search: work-card fields are not searched, only text parts", A, { query: "running", limit: 10 }),
    run("search: no match", A, { query: "nothing here", limit: 10 }),
    run("search: another member sees their own conversations", B, { query: "deploy", limit: 100 }),
    run("search: empty query", A, { query: "   ", limit: 10 }),
    run("search: a control character in the query", A, { query: "dep\u0007loy", limit: 10 }),
    run("search: limit 0", A, { query: "deploy", limit: 0 }),
    run("search: limit 101", A, { query: "deploy", limit: 101 })
  ]
}
