import { describe, expect, it } from "vitest"
import { teamAuthorityVersion } from "../src/domains/team-authority.ts"
import { reduceMemberProvision } from "../src/domains/team-stack.ts"

const rows = (incarnation: string) => ({
  get: (table: string, key: string) => table === "member_authority" && key === "alice" ? { row: { incarnation } } : table === "member_authority" && key === "@generation" ? { row: { generation: "2" } } : undefined
}) as any

describe("team membership authority", () => {
  it("fences an ABA role transition and a new incarnation", () => {
    const owner = teamAuthorityVersion("team", "alice", "owner", "stack", 1, rows("generation:1:aaaaaaaaaaaaaaaaaaaaaa"))
    const member = teamAuthorityVersion("team", "alice", "member", "stack", 1, rows("generation:1:aaaaaaaaaaaaaaaaaaaaaa"))
    const ownerAgain = teamAuthorityVersion("team", "alice", "owner", "stack", 1, rows("generation:2:bbbbbbbbbbbbbbbbbbbbbb"))
    expect(member).not.toBe(owner)
    expect(ownerAgain).not.toBe(owner)
  })

  it("writes a fresh authority row for each reducer role transition", () => {
    const user = "user_aaaaaaaaaaaaaaaaaaaa"
    let member: any
    const rows = { get: (table: string, key: string) => table === "member" && member ? { row: member } : undefined } as any
    const run = (role: "owner" | "member", tx: string) => reduceMemberProvision({ team: { id: "team_aaaaaaaaaaaaaaaaaaaa", kind: "stack", display_name: "Team" }, member_count: member ? 1 : 0, seat_count: member ? 1 : 0, owner_count: role === "owner" ? 1 : 0 } as any, { user, role, source: "stack", display_name: "Alice" }, { principal: { kind: "system", identity: "system:team" }, rows, tx, now: 1 } as any)
    const first = run("owner", "A".repeat(22)); member = { user, role: "owner", display_name: "Alice" }
    const second = run("member", "B".repeat(22)); member = { user, role: "member", display_name: "Alice" }
    const third = run("owner", "C".repeat(22))
    const authority = (r: any) => r.writes.find((w: any) => w.table === "member_authority" && w.key === user).row.incarnation
    expect(new Set([authority(first), authority(second), authority(third)]).size).toBe(3)
  })
})
