import { describe, expect, it } from "vitest"
import { teamAuthorityVersion } from "../src/domains/team-authority.ts"

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
})
