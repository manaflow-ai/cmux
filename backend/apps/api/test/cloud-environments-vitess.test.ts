import { describe, expect, it } from "vitest"
import { projectionStatementMysql } from "../src/projection-mysql.ts"

/** The Vitess projection of Cloud environments (cloud-environments-DESIGN.md §7): MySQL only, source-guarded. */
describe("cloud_environments projection", () => {
  it("upserts under the source guard and soft-deletes so a replayed older upsert cannot bring a row back", () => {
    const up = projectionStatementMysql("cloud.environment.upsert", { id: "env_00000000000000000001", team_id: "team_1", name: "web", repo: "a/b", status: "ready", snapshot_id: "snap_00000000000000000001", created_by: "user_1", created_at: 1, updated_at: 2 }, "cloud:team_1", 7)
    expect(up?.[0]).toMatch(/^insert into `cloud_environments`/)
    expect(up?.[0]).toContain("on duplicate key update")
    const del = projectionStatementMysql("cloud.environment.delete", { id: "env_00000000000000000001", team_id: "team_1" }, "cloud:team_1", 8)
    expect(del?.[0]).toMatch(/^update `cloud_environments` set `deleted_at` = CURRENT_TIMESTAMP\(3\)/)
    expect(del?.[0]).toContain("`source_seq` < ?")
    expect(del?.[1]).toEqual(expect.arrayContaining(["team_1", "env_00000000000000000001", "cloud:team_1", 8]))
  })
})
