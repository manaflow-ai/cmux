import { describe, expect, it } from "vitest"
import { deliver, mirroredTeam, stackWorld, teamIdOf, teamState, useStack } from "./team-stack-support.ts"

/**
 * cx-3bi.43 P1 from the staging endpoint: Svix "Send Example" for team.deleted got 400 "malformed
 * webhook body". Stack's published examples (docs-mintlify/openapi/webhooks.json, the schema
 * `example` Svix sends) carry only the type, no data. A signed delivery must never answer 4xx:
 * Svix retries a 4xx and then disables the endpoint. What we cannot use is a logged 200 no-op.
 */
const EXAMPLES: Record<string, string> = {
  "team.created": '{"type":"team.created"}',
  "team.updated": '{"type":"team.updated"}',
  "team.deleted": '{"type":"team.deleted"}',
  "team_membership.created": '{"type":"team_membership.created"}',
  "team_membership.deleted": '{"type":"team_membership.deleted"}'
}

describe("Stack webhook payload shapes (cx-3bi.43)", { timeout: 60_000 }, () => {
  for (const [type, body] of Object.entries(EXAMPLES)) {
    it(`Stack's ${type} example (type only, no data) answers 200 ignored_shape`, async () => {
      const r = await deliver(type, undefined, { rawBody: body })
      expect(r.status, JSON.stringify(r.body)).toBe(200)
      expect(r.body).toMatchObject({ ok: true, ignored: "shape" })
    })
  }

  it("a signed body that is not JSON, not an object, or has no type answers 200 ignored_shape", async () => {
    for (const body of ["not json", "[]", "null", '{"data":{}}', '{"type":"team.created","data":"x"}']) {
      const r = await deliver("team.created", undefined, { rawBody: body })
      expect(r.status, body).toBe(200)
      expect(r.body, body).toMatchObject({ ok: true, ignored: "shape" })
    }
  })

  it("the full team.created example with metadata and unknown fields is processed", async () => {
    const w = stackWorld()
    const stackTeam = "ad962777-8244-496a-b6a2-e0c6a449c79e".replace(/^ad96/, crypto.randomUUID().slice(0, 4))
    await useStack(stackTeam, w)
    w.teams.set(stackTeam, "My Team")
    const data = { created_at_millis: 1630000000000, server_metadata: { key: "value" }, id: stackTeam, display_name: "My Team", profile_image_url: "https://example.com/image.jpg", client_metadata: { key: "value" }, client_read_only_metadata: { key: "value" }, extra_future_field: 1 }
    const r = await deliver("team.created", data)
    expect(r.status).toBe(200)
    expect(r.body).toMatchObject({ ok: true, outcome: "team_mirrored" })
    expect((await teamState(teamIdOf(stackTeam))).team).toMatchObject({ kind: "stack", display_name: "My Team" })
  })

  it("a membership id that is not a UUID but a bounded token is accepted", async () => {
    const t = await mirroredTeam()
    const r = await deliver("team_membership.deleted", { team_id: t.stackTeam, user_id: "user_not_uuid-123" })
    expect(r.status).toBe(200)
    expect(r.body.ignored).toBeUndefined()
  })
})
