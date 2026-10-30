import { describe, expect, it } from "vitest"
import type { Principal } from "@cmux/ownership"
import { allowedServices } from "../src/cloud-connect.ts"
import { mayDelete, mayManage, type MachineRow } from "../src/domains/cloud.ts"

const row = (visibility?: "team" | "private"): MachineRow => ({
  id: "vm_aaaaaaaaaaaaaaaaaaaa",
  team: "team_shared",
  creator: "user_creator",
  name: null,
  size: { cpu: 2, memory_mb: 4096, disk_mb: 16384 },
  status: "running",
  image: { id: "img", daemon_version: null },
  host: null,
  classic: false,
  created_at: 1,
  last_active_at: null,
  idle_policy: { idle_seconds: 900 },
  error: null,
  revision: "1",
  provider_name: "vm",
  ...(visibility ? { visibility } : {}),
})
const member: Principal = { identity: "session:user_mate", kind: "session", user: "user_mate", team: "team_shared" }
const creator: Principal = { identity: "session:user_creator", kind: "session", user: "user_creator", team: "team_shared" }

describe("team machine access enrollment", () => {
  it("keeps legacy rows creator/admin-only while enrolled team rows are manageable", () => {
    expect(mayManage(member, row())).toBe(false)
    expect(mayManage(member, row("team"))).toBe(true)
    expect(mayDelete(member, row("team"))).toBe(false)
    expect(mayDelete(creator, row("team"))).toBe(true)
  })

  it("does not attach a teammate to a private row", () => {
    expect(allowedServices("team_shared", row("private"), member, ["daemon", "ssh"])).toMatchObject({ ok: false })
    expect(allowedServices("team_shared", row("team"), member, ["daemon", "ssh"])).toMatchObject({ ok: true })
  })
})
