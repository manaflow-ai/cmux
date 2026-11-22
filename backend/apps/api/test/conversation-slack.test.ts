import { conversation } from "@cmux/home-core"
import type { Principal, RowReader, StoredRow } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import type { SlackInbound } from "../src/chief-slack.ts"
import { slackOutbound, slackThread, withSlack } from "../src/conversation-slack.ts"

const owner = "user_slackowner", chief = "agent_slackchief", root = "msg_slackroot"
const at = "2026-11-02T12:00:00.000Z"
const inbound: SlackInbound = { slackTeamId: "T123", channelId: "C123", slackUserId: "U123", slackUserName: "Alice", isOwner: true, text: "Hello Chief", ts: "123.001", threadTs: "123.001", permalink: "https://example.slack.com/archives/C123/p123001", ownerUserId: owner, cmuxTeamId: "team_slack", channelName: "general" }
const session: Principal = { kind: "session", identity: "session:owner", user: owner }
const system: Principal = { kind: "system", identity: "system:slack" }

const harness = () => {
  let head: conversation.ConversationState = {
    id: "conv_slack", kind: "chief", title: "Chief", rev: 1, last_seq: 0, created_at: at, updated_at: at, read_cursors: {},
    participants: [{ id: owner, kind: "human", display_name: "Alice", role: "owner" }, { id: chief, kind: "agent", display_name: "Chief", agent_class: "mux", owner_user: owner }]
  }
  const data = new Map<string, Map<string, StoredRow>>()
  const rows: RowReader = {
    get: <T>(table: string, key: string) => data.get(table)?.get(key) as StoredRow<T> | undefined,
    range: <T>(table: string, q: { limit: number; desc?: boolean; after?: number; before?: number }) => [...(data.get(table)?.values() ?? [])].filter((r) => r.n !== null && r.n > (q.after ?? -1) && r.n < (q.before ?? Infinity)).sort((a, b) => q.desc ? b.n! - a.n! : a.n! - b.n!).slice(0, q.limit) as Array<StoredRow<T>>
  }
  const domain = withSlack(conversation.makeConversationDomain())
  let n = 0
  const submit = (op: string, params: Record<string, unknown>, principal = system) => {
    const result = domain.reduce(head, op, params, { principal, now: Date.parse(at) + ++n * 3000, tx: `tx${n}`, newId: () => `msg_${n}`, rows })
    if (result.ok) {
      head = result.state
      for (const write of result.writes ?? []) {
        if (!data.has(write.table)) data.set(write.table, new Map())
        if (write.op === "delete") data.get(write.table)!.delete(write.key)
        else data.get(write.table)!.set(write.key, { key: write.key, n: write.n ?? null, row: write.row })
      }
    }
    return result
  }
  const receive = (patch: Partial<SlackInbound> = {}, thread = root, principal = system) => submit("slack.message", { owner, agent: chief, root: thread, inbound: { ...inbound, ...patch } }, principal)
  const message = (id: string) => rows.get<conversation.Message>(conversation.TABLE_MSG, id)!.row
  const send = (text: string, target?: string, actor = owner) => {
    const key = `send${n}`
    const result = submit("message.send", { client_msg_id: key, parts: [{ type: "text", text }], ...(target ? { reply_to: { message_id: target, part_index: 0 } } : {}) }, actor === chief ? { identity: "chief", kind: "agent", agent: chief, user: owner } : { ...session, user: actor })
    if (!result.ok) throw new Error(result.code)
    return message((result.value as { message_id: string }).message_id)
  }
  return { submit, receive, message, send, rows, expire: (id: string) => data.get(conversation.TABLE_MSG)?.delete(id), state: () => head! }
}

describe("Slack conversation adapter", () => {
  it("creates one root, stores the Slack author, and reuses the thread on reply and redelivery", () => {
    const h = harness()
    const first = h.receive()
    expect(first.ok).toBe(true)
    expect(h.message(root)).toMatchObject({ author: "slack:T123:U123", slack: { isOwner: true }, thread: { source: "slack", channelName: "general", permalink: inbound.permalink } })
    expect(h.state().participants.find((p) => p.id === "slack:T123:U123")?.display_name).toBe("Alice")
    const second = h.receive({ ts: "123.002", slackUserId: "U456", slackUserName: "Bob", isOwner: false })
    expect(second.ok).toBe(true)
    if (!second.ok) return
    const id = (second.value as { message_id: string }).message_id
    expect(h.message(id)).toMatchObject({ author: "slack:T123:U456", thread_root: root, slack: { isOwner: false } })
    const replay = h.receive({ ts: "123.002", slackUserId: "U456", slackUserName: "Bob", isOwner: false })
    expect(replay).toMatchObject({ ok: true, changed: false, value: { message_id: id, seq: 2 } })
    expect(h.state().last_seq).toBe(2)
  })

  it("dedupes by workspace, channel and timestamp regardless of delivery metadata", () => {
    const h = harness()
    expect(h.receive()).toMatchObject({ ok: true, value: { message_id: root, seq: 1 } })
    expect(h.receive({ slackUserId: "UOTHER", slackUserName: "Updated", text: "Redelivered", threadTs: "999.001" }, "msg_other")).toMatchObject({ ok: true, changed: false, value: { message_id: root, seq: 1 } })
    expect(h.state().last_seq).toBe(1)
    expect(h.message(root)).toMatchObject({ author: "slack:T123:U123", parts: [{ type: "text", text: inbound.text }] })
    expect(h.receive({ channelId: "COTHER" }, "msg_channel")).toMatchObject({ ok: true, value: { seq: 2 } })
    expect(h.receive({ slackTeamId: "TOTHER" }, "msg_team")).toMatchObject({ ok: true, value: { seq: 3 } })
  })

  it("acknowledges an expired tuple without recreating its message", () => {
    const h = harness()
    expect(h.receive()).toMatchObject({ ok: true })
    h.expire(root)
    expect(h.receive({ slackUserName: "Updated" })).toMatchObject({ ok: true, changed: false, value: { message_id: root, expired: true } })
    expect(h.rows.get(conversation.TABLE_MSG, root)).toBeUndefined()
    expect(h.state().last_seq).toBe(1)
  })

  it("never exposes Slack injection to a normal principal or another Chief's owner", () => {
    const h = harness()
    expect(h.receive({}, root, session)).toMatchObject({ ok: false, code: "forbidden" })
    expect(h.receive({ ownerUserId: "user_other" })).toMatchObject({ ok: false, code: "forbidden" })
    expect(h.receive({}, root, { kind: "system", identity: "system:other" })).toMatchObject({ ok: false, code: "forbidden" })
    expect(h.state().last_seq).toBe(0)
  })

  it("rejects a root belonging to another Slack channel", () => {
    const h = harness()
    h.receive()
    expect(h.receive({ channelId: "C999", ts: "123.002" })).toMatchObject({ ok: false, code: "invalid_thread_root" })
  })

  it("does not queue a second brain wake or create cloud inboxes for Slack identities", () => {
    const h = harness()
    const result = h.receive()
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.outbox?.some((o) => o.kind === "mux.wake")).toBe(false)
    expect(result.outbox?.some((o) => o.target?.name.startsWith("slack:"))).toBe(false)
    expect(result.outbox?.some((o) => o.kind === "inbox.bump" && o.target?.name === owner)).toBe(true)
  })

  it("keeps transport metadata when the owner clears the thread title", () => {
    const h = harness()
    h.receive()
    expect(h.submit("thread.update", { root, title: "" }, session).ok).toBe(true)
    expect(slackThread(h.message(root))).toMatchObject({ source: "slack", channelId: "C123", chief, ownerUserId: owner })
  })

  it("selects Chief and owner replies only, prefixes the owner, and follows reply-only ancestry", () => {
    const h = harness()
    h.receive()
    const own = h.send("Answer", root)
    expect(slackOutbound(h.rows, own, h.state())).toMatchObject({ agent: chief, root, message: own.id, text: "Alice: Answer" })
    const answer = h.send("Chief answer", own.id, chief)
    expect(slackOutbound(h.rows, answer, h.state())).toMatchObject({ root, text: "Chief answer" })
    expect(slackOutbound(h.rows, h.message(root), h.state())).toBeUndefined()
    expect(slackOutbound(h.rows, h.send("Normal chat"), h.state())).toBeUndefined()
  })
})
