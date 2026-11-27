import { readFileSync } from "node:fs"
import { describe, expect, it } from "vitest"
import { searchConversations, type SearchSource } from "../src/conversation/search.ts"
import type { ConversationHead } from "../src/conversation/types.ts"

const corpus = JSON.parse(readFileSync(new URL("../conformance/conversation-search-cases.json", import.meta.url), "utf8")) as {
  cases: Array<{ name: string; actor: string; input: { query: string; limit: number }; sources: Array<SearchSource>; expect: { hits?: unknown; reject?: string } }>
}

describe("conversation-search corpus", () => {
  for (const c of corpus.cases)
    it(c.name, () => {
      const r = searchConversations(c.actor, c.input, c.sources)
      expect(r.ok ? { hits: r.hits } : { reject: r.code }).toEqual(c.expect)
    })
})

describe("conversation-search visibility", () => {
  it("hides history before joining when the group says since_join, and skips address participants", () => {
    const head = {
      id: "conv_G", title: "G", kind: "group", last_seq: 3, rev: 4, created_at: "x", updated_at: "x", read_cursors: {},
      settings: { history_visible: "since_join" },
      participants: [
        { id: "user_a", kind: "human", display_name: "a", joined_seq: 0 },
        { id: "user_late", kind: "human", display_name: "l", joined_seq: 2 },
        { id: "addr_X", kind: "address", display_name: "x", joined_seq: 0 }
      ]
    } as unknown as ConversationHead
    const m = (seq: number) => ({ id: `msg_${seq}`, conversation: "conv_G", seq, client_msg_id: `c${seq}`, author: "user_a", parts: [{ type: "text" as const, text: "plan" }], created_at: `2026-10-02T00:00:0${seq}.000Z`, reactions: [] })
    const sources = [{ head, messages: [m(1), m(2), m(3)] }]
    const seqs = (actor: string) => { const r = searchConversations(actor, { query: "plan", limit: 10 }, sources); return r.ok ? r.hits.map((h) => h.seq) : r.code }
    expect(seqs("user_a")).toEqual([3, 2, 1])
    expect(seqs("user_late")).toEqual([3])
    expect(seqs("addr_X")).toEqual([])
  })
})
