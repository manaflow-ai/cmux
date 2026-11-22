import { describe, expect, it } from "vitest"
import { projectionStatement } from "../src/projection.ts"

const conv = { id: "conv_01JB8Q3Z5X7Y9K2M4N6P8R0T2V", kind: "group", team_id: null, title: "Launch", created_by: "user_a", created_at: "2026-10-02T10:00:00.000Z", last_seq: 3, last_at: "2026-10-02T10:05:00.000Z", participant_count: 2, state: "active" }

describe("Home projection statements (migration 0006)", () => {
  it("maps every Home outbox kind to its table, guarded by source_seq", () => {
    const kinds: Record<string, string> = {
      "home.conversation.upsert": "home_conversations",
      "home.participant.upsert": "home_participants",
      "home.message.upsert": "home_message_search",
      "home.message.delete": "home_message_search",
      "home.message.delete_through": "home_message_search",
      "home.invite.upsert": "home_invites"
    }
    for (const [kind, table] of Object.entries(kinds)) {
      const st = projectionStatement(kind, { conversation_id: conv.id, seq: 1, id: "x", participant_id: "user_a", kind: "human" }, "conv:x", 7)
      expect(st, kind).toBeDefined()
      expect(st![0]).toContain(table)
      expect(st![0]).toMatch(/source_seq"? (<|<=)/)
      expect(st![1]).toContain(7)
    }
  })

  it("conversation upsert carries the projection fields in order", () => {
    // Exact SQL and order are Drizzle's; backend/db/test-pg/projection.test.ts checks the behavior on Postgres.
    const [sql, params] = projectionStatement("home.conversation.upsert", conv, "conv:x", 4)!
    expect(sql).toMatch(/"home_conversations"\."source_seq" < excluded\."source_seq"/)
    for (const v of [conv.id, "group", "Launch", "user_a", conv.created_at, 3, conv.last_at, 2, "active", "conv:x", 4]) expect(params).toContain(v)
  })

  it("participant upsert keeps the stored joined_at when the payload omits it", () => {
    const [sql, params] = projectionStatement("home.participant.upsert", { conversation_id: conv.id, participant_id: "user_b", kind: "human", visible_from_seq: 0, left_at: null }, "conv:x", 5)!
    expect(sql).toContain(`"joined_at" = "home_participants"."joined_at"`)
    expect(params).not.toContain(undefined)
  })

  it("invites project the HMAC address id and never an address, secret or token hash", () => {
    const invite = { id: "inv_1", conversation_id: conv.id, invited_by: "user_a", address_id: "addr_X", channel: "sms", status: "pending", delivery_state: "queued", copy_variant: "A", created_at: conv.created_at, expires_at: conv.last_at, accepted_by: null, accepted_at: null, token_hash: "SHOULD-NOT-APPEAR", address: "+15555550100" }
    const [sql, params] = projectionStatement("home.invite.upsert", invite, "conv:x", 6)!
    expect(sql).not.toMatch(/token|secret/)
    expect(JSON.stringify(params)).not.toContain("SHOULD-NOT-APPEAR")
    expect(JSON.stringify(params)).not.toContain("+15555550100")
    expect(params).toContain("addr_X")
  })

  it("message delete removes the row only when no newer write replaced it", () => {
    const [sql, params] = projectionStatement("home.message.delete", { conversation_id: conv.id, seq: 9 }, "conv:x", 12)!
    expect(sql).toContain("source_seq <= $4")
    expect(params).toEqual([conv.id, 9, "conv:x", 12])
  })

  it("retention deletes every search row of the conversation through a seq, one statement per sweep", () => {
    const [sql, params] = projectionStatement("home.message.delete_through", { conversation_id: conv.id, seq: 40 }, "conv:x", 41)!
    expect(sql).toContain("seq <= $2")
    expect(sql).toContain("source_seq <= $4")
    expect(params).toEqual([conv.id, 40, "conv:x", 41])
  })
})
