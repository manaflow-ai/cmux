import { expect, it } from "vitest"
import { vmApiTenantOf } from "../src/team-vm-api-tenant.ts"
import { teamDomain } from "../src/domains/team.ts"
import { personalTeamIdFor, stackTeamIdFor } from "../src/domains/user.ts"
import { call, deliver, mirroredTeam, PROJECT, teamState, teamStub } from "./team-stack-support.ts"
import { inDO } from "./team-ssh-support.ts"

interface TenantReader {
  vmApiTenant(entity: string, purpose: "operate" | "cleanup"): Promise<{ team: string; tenant: string; project: string } | null>
}
const reader = (team: string) => teamStub(team) as unknown as TenantReader

it("resolves a mirrored Stack team through its owner, without exposing member data", async () => {
  const t = await mirroredTeam("VM API tenant")
  const before = await teamState(t.team)
  const revision = await inDO(teamStub(t.team), async (instance) => instance.boundEngine.currentSeq)
  expect(await reader(t.team).vmApiTenant(t.team, "operate")).toEqual({ team: t.team, tenant: t.stackTeam, project: PROJECT })
  expect(await teamState(t.team)).toEqual(before)
  expect(await inDO(teamStub(t.team), async (instance) => instance.boundEngine.currentSeq)).toBe(revision)
})

it("does not guess a Stack tenant for a synthetic personal team", async () => {
  const t = await mirroredTeam("Personal guard")
  const personal = personalTeamIdFor(t.user)
  expect((await teamState(personal)).team).toMatchObject({ kind: "personal" })
  expect(await reader(personal).vmApiTenant(personal, "operate")).toBeNull()
  expect(await reader(personal).vmApiTenant(personal, "cleanup")).toBeNull()
})

it("does not create an unknown team or retarget another team's owner", async () => {
  const t = await mirroredTeam("Bound team")
  const unknown = `team_${crypto.randomUUID().replace(/-/g, "").slice(0, 20)}`
  expect(await reader(unknown).vmApiTenant(unknown, "operate")).toBeNull()
  expect((await teamState(unknown)).team).toBeNull()
  expect(await inDO(teamStub(unknown), async (_instance, state) => state.storage.sql.exec("SELECT name FROM sqlite_master WHERE type = 'table' AND (name LIKE 'own_%' OR name = 'do_entity')").toArray())).toEqual([])
  expect(await reader(t.team).vmApiTenant(unknown, "operate")).toBeNull()
  expect(await reader(t.team).vmApiTenant(t.team, "operate")).toEqual({ team: t.team, tenant: t.stackTeam, project: PROJECT })
})

it("denies deleted teams new operations but retains their exact tenant for cleanup", async () => {
  const t = await mirroredTeam("Deleted guard")
  t.w.teams.delete(t.stackTeam)
  expect((await deliver("team.deleted", { id: t.stackTeam })).status).toBe(200)
  expect((await teamState(t.team)).team).toHaveProperty("deleted_at")
  expect(await reader(t.team).vmApiTenant(t.team, "operate")).toBeNull()
  expect(await reader(t.team).vmApiTenant(t.team, "cleanup")).toEqual({ team: t.team, tenant: t.stackTeam, project: PROJECT })
})

it("refuses a stored Stack ID that does not derive this owner in the configured project", async () => {
  const t = await mirroredTeam("Mismatched guard")
  await inDO(teamStub(t.team), async (instance) => {
    instance.submitSystem("team.stack_mirror", { team: t.team, stack_team: crypto.randomUUID(), display_name: "Mismatch" }, crypto.randomUUID())
  })
  expect(await reader(t.team).vmApiTenant(t.team, "operate")).toBeNull()
  expect(await reader(t.team).vmApiTenant(t.team, "cleanup")).toBeNull()
})

it("keeps the Stack tenant out of the public team membership view", async () => {
  const t = await mirroredTeam("Public guard")
  const response = await call(t.token, "/v1/read", { op: "team.directory", params: {} }, t.team)
  expect(response.status).toBe(200)
  expect(response.body).toMatchObject({ value: { team: t.team } })
  expect(JSON.stringify(response.body)).not.toContain(t.stackTeam)
})

it("refuses an unknown RPC purpose rather than treating it as cleanup", async () => {
  const t = await mirroredTeam("Purpose guard")
  const malformed = teamStub(t.team) as unknown as { vmApiTenant(entity: string, purpose: string): Promise<unknown> }
  expect(await malformed.vmApiTenant(t.team, "execute-as-cleanup")).toBeNull()
})

it("does not route a valid mirror through a different configured Stack project", () => {
  const tenant = crypto.randomUUID()
  const entity = stackTeamIdFor(PROJECT, tenant)
  const state = { ...teamDomain.initial(), team: { id: entity, kind: "stack" as const, display_name: "Fixture", stack_team: tenant } }
  expect(vmApiTenantOf(state, entity, PROJECT, "operate")).toEqual({ team: entity, tenant, project: PROJECT })
  // Even cleanup cannot use a mapping whose project does not derive its owner.
  expect(vmApiTenantOf(state, entity, "different-project", "cleanup")).toBeNull()
})
