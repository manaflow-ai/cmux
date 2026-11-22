import { describe, expect, it } from "vitest"
import { conversationRedact } from "../src/conversation/redact.ts"
import { conversationDomain } from "../src/conversation/domain.ts"
import { dmPeer, inboxDomain, TABLE_PEER } from "../src/inbox/domain.ts"
import { INITIAL_INBOX_HEAD } from "../src/inbox/reducer.ts"
import { MemoryRows } from "./support/harness.ts"

const NOW = 1_790_000_000_000
const system = { identity: "system:conv", kind: "system" as const }

describe("engine integration (PR 16827 answers)", () => {
  it("indexes the first DM per peer for inbox.dm_peer", () => {
    const rows = new MemoryRows()
    let head = INITIAL_INBOX_HEAD
    const bump = (conversation: string, rev: number) => {
      const r = inboxDomain.reduce(head, "inbox.bump", { user: "user_a", conversation, rev, kind: "dm", title: "", last_seq: rev, last_at: "2026-10-02T00:00:00.000Z", preview: "", unread: 0, mentions: 0, dm_peer: "user_b" }, { principal: system, now: NOW, tx: `t${rev}`, newId: (p) => `${p}1`, rows })
      if (!r.ok) throw new Error(r.code)
      head = r.state
      rows.apply(r.writes ?? [])
    }
    bump("conv_dm_FIRST", 1)
    bump("conv_dm_SECOND", 1)
    expect(dmPeer(rows, "user_b")).toBe("conv_dm_FIRST")
    expect(dmPeer(rows, "user_c")).toBeNull()
    expect(rows.get(TABLE_PEER, "user_b")?.row).toEqual({ conversation: "conv_dm_FIRST" })
  })

  it("refuses a message whose client_msg_id is not the idempotency key, when the engine passes the key", () => {
    const head = { id: "conv_X", kind: "group" } as never
    const ctx = { principal: { identity: "u", kind: "session" as const, user: "user_a" }, now: NOW, tx: "t", newId: (p: string) => `${p}1`, rows: new MemoryRows(), idempotencyKey: "other-key" }
    const r = conversationDomain.reduce(head, "message.send", { client_msg_id: "k1", parts: [{ type: "text", text: "hi" }] }, ctx)
    expect(r).toMatchObject({ ok: false, code: "invalid_client_msg_id" })
  })

  it("redacts token hashes and proofs from what subscribers see", () => {
    expect(conversationRedact.params("invite.create", { invite_id: "inv_1", token_hash: "h" })).toEqual({ invite_id: "inv_1" })
    expect(conversationRedact.params("invite.accept", { proof: "p" })).toEqual({})
    expect(conversationRedact.params("message.send", { client_msg_id: "k" })).toEqual({ client_msg_id: "k" })
    expect(conversationRedact.state({ id: "c", invites: [{ id: "inv_1", token_hash: "h" }] })).toEqual({ id: "c", invites: [{ id: "inv_1" }] })
    expect(conversationRedact.row("inv", { id: "inv_1", token_hash: "h" })).toEqual({ id: "inv_1" })
    expect(conversationRedact.row("invhash", { invite_id: "inv_1" })).toEqual({})
    expect(conversationRedact.row("msg", { id: "m" })).toEqual({ id: "m" })
  })
})
