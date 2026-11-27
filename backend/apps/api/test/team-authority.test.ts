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
    const persisted = new Map<string, any>()
    const rows = { get: (table: string, key: string) => { const row = persisted.get(`${table}:${key}`); return row === undefined ? undefined : { row } } } as any
    const apply = (r: any) => { for (const w of r.writes ?? []) persisted.set(`${w.table}:${w.key}`, w.op === "delete" ? undefined : w.row) }
    let state: any = { team: { id: "team_aaaaaaaaaaaaaaaaaaaa", kind: "stack", display_name: "Team" }, member_count: 0, seat_count: 0, owner_count: 0 }
    const run = (role: "owner" | "member", tx: string) => { const r = reduceMemberProvision(state, { user, role, source: "stack", display_name: "Alice" }, { principal: { kind: "system", identity: "system:team" }, rows, tx, now: 1 } as any); if (r.ok) { state = r.state; apply(r) }; return r }
    run("owner", "A".repeat(22)); const first = persisted.get(`member_authority:${user}`).incarnation
    run("member", "B".repeat(22)); const second = persisted.get(`member_authority:${user}`).incarnation
    run("owner", "C".repeat(22)); const third = persisted.get(`member_authority:${user}`).incarnation
    expect(persisted.get("member_authority:@generation").generation).toBe("3")
    expect(new Set([first, second, third]).size).toBe(3)
    expect(teamAuthorityVersion(state.team.id, user, "owner", "stack", 0, rows)).not.toBe(teamAuthorityVersion(state.team.id, user, "member", "stack", 0, rows))
  })
})
