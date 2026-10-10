import { describe, expect, it } from "vitest"
import { projectionStatement } from "../src/projection.ts"

const conv = { id: "conv_01JB8Q3Z5X7Y9K2M4N6P8R0T2V", kind: "group", team_id: null, title: "Launch", created_by: "user_a", created_at: "2026-10-02T10:00:00.000Z", last_seq: 3, last_at: "2026-10-02T10:05:00.000Z", participant_count: 2, state: "active" }

describe("Home projection statements (migration 0006)", () => {

  it("invites project the HMAC address id and never an address, secret or token hash", () => {
    const invite = { id: "inv_1", conversation_id: conv.id, invited_by: "user_a", address_id: "addr_X", channel: "sms", status: "pending", delivery_state: "queued", copy_variant: "A", created_at: conv.created_at, expires_at: conv.last_at, accepted_by: null, accepted_at: null, token_hash: "SHOULD-NOT-APPEAR", address: "+15555550100" }
    const [sql, params] = projectionStatement("home.invite.upsert", invite, "conv:x", 6)!
    expect(sql).not.toMatch(/token|secret/)
    expect(JSON.stringify(params)).not.toContain("SHOULD-NOT-APPEAR")
    expect(JSON.stringify(params)).not.toContain("+15555550100")
    expect(params).toContain("addr_X")
  })

})
