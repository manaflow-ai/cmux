import { describe, expect, it } from "vitest"
import { personalTeamIdFor } from "../src/domains/user.ts"
import { fireAlarm } from "./setup/alarm.ts"
import { deliver, mirroredTeam, teamState, teamStub } from "./team-stack-support.ts"
import { inDO } from "./team-ssh-support.ts"

/**
 * Leo deleted a Stack team that carried its own operator Cloud grant (`cmuxVmPlan` on the Stack team
 * record), and the grant went with it: "i removed leo@cmux.com's team and so now it's just personal".
 * Stack's team.deleted names only the team id, so TeamDO keeps a copy of the grant from every team sync
 * and, when Stack confirms the delete, carries it to the single owner's personal grant, keeping the
 * higher of the two, and records what it did.
 */

type Carried = { stack_team: string; vm_plan: string; outcome: string; owner: string | null; to_team: string | null }
const carried = (team: string) =>
  inDO(teamStub(team), async (_instance, state) => {
    const sql = state.storage.sql
    if (sql.exec(`SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'cloud_vm_plan_carried'`).toArray().length === 0) return null
    return (sql.exec(`SELECT stack_team, vm_plan, outcome, owner, to_team FROM cloud_vm_plan_carried`).toArray()[0] as Carried | undefined) ?? null
  })

/** A mirrored Stack team whose one member owns it, with `grant` on its Stack record, synced so TeamDO has read it. */
const ownedTeamWithGrant = async (grant: string | null) => {
  const t = await mirroredTeam()
  t.w.perms.set(`${t.stackTeam}:${t.stackUser}`, ["$delete_team"])
  if (grant !== null) t.w.vmPlans.set(t.stackTeam, grant)
  expect((await deliver("team.updated", { id: t.stackTeam, display_name: "Acme" })).status).toBe(200)
  return t
}

const deleteInStack = async (t: Awaited<ReturnType<typeof mirroredTeam>>) => {
  t.w.teams.delete(t.stackTeam)
  t.w.vmPlans.delete(t.stackTeam)
  return deliver("team.deleted", { id: t.stackTeam })
}

describe("a Stack team delete never strands its Cloud grant (ask-7b9075082b)", { timeout: 60_000 }, () => {
  it("carries the deleted team's grant to its owner's personal grant and records that it moved", async () => {
    const t = await ownedTeamWithGrant("max")
    const r = await deleteInStack(t)
    expect(r.status).toBe(200)
    expect((await teamState(t.team)).team?.deleted_at).toBeTypeOf("number")
    expect(t.w.userVmPlanWrites).toEqual([{ user: t.stackUser, vm_plan: "max" }])
    expect(await carried(t.team)).toEqual({ stack_team: t.stackTeam, vm_plan: "max", outcome: "moved", owner: t.user, to_team: personalTeamIdFor(t.user) })
  })

  it("keeps the owner's own grant when it is already as high or higher", async () => {
    const t = await ownedTeamWithGrant("pro")
    t.w.userVmPlans.set(t.stackUser, "max")
    expect((await deleteInStack(t)).status).toBe(200)
    expect(t.w.userVmPlanWrites).toEqual([])
    expect(t.w.userVmPlans.get(t.stackUser)).toBe("max")
    expect((await carried(t.team))?.outcome).toBe("kept_existing")
  })

  it("raises a lower personal grant to the team's higher one", async () => {
    const t = await ownedTeamWithGrant("max")
    t.w.userVmPlans.set(t.stackUser, "go")
    expect((await deleteInStack(t)).status).toBe(200)
    expect(t.w.userVmPlanWrites).toEqual([{ user: t.stackUser, vm_plan: "max" }])
    expect((await carried(t.team))?.outcome).toBe("moved")
  })

  it("writes nothing for a team without a grant", async () => {
    const t = await ownedTeamWithGrant(null)
    expect((await deleteInStack(t)).status).toBe(200)
    expect((await teamState(t.team)).team?.deleted_at).toBeTypeOf("number")
    expect(t.w.userVmPlanWrites).toEqual([])
    expect(await carried(t.team)).toBeNull()
  })

  it("with two owners it moves nothing, keeps the grant on record for an operator, and still deletes the team", async () => {
    const t = await ownedTeamWithGrant("max")
    const second = crypto.randomUUID()
    t.w.members.set(`${t.stackTeam}:${second}`, "Bea")
    t.w.perms.set(`${t.stackTeam}:${second}`, ["$delete_team"])
    expect((await deliver("team.updated", { id: t.stackTeam, display_name: "Acme" })).status).toBe(200)
    expect((await deleteInStack(t)).status).toBe(200)
    expect((await teamState(t.team)).team?.deleted_at).toBeTypeOf("number")
    expect(t.w.userVmPlanWrites).toEqual([])
    expect(await carried(t.team)).toMatchObject({ vm_plan: "max", outcome: "no_single_owner", owner: null, to_team: null })
  })

  it("a failed grant write leaves the team undeleted and the alarm retries until the grant has moved", async () => {
    const t = await ownedTeamWithGrant("max")
    t.w.failWrites.left = 1
    expect((await deleteInStack(t)).body).toMatchObject({ ok: true, outcome: "queued" })
    expect((await teamState(t.team)).team?.deleted_at).toBeUndefined()
    expect(await carried(t.team)).toBeNull()
    await inDO(teamStub(t.team), async (_instance, state) => {
      state.storage.sql.exec(`UPDATE stack_team_recheck SET due_at = 0`)
    })
    await fireAlarm(teamStub(t.team))
    // The retry's synthetic delivery id once made a 129-character idempotency key, refused, so the delete was dropped.
    expect((await teamState(t.team)).team?.deleted_at).toBeTypeOf("number")
    expect(t.w.userVmPlanWrites).toEqual([{ user: t.stackUser, vm_plan: "max" }])
    expect((await carried(t.team))?.outcome).toBe("moved")
  })

  it("an owner the API has never seen keeps the grant on record instead of losing it", async () => {
    const t = await ownedTeamWithGrant("max")
    const stranger = crypto.randomUUID()
    // A second Stack member who never signed in to cmux becomes the only owner.
    t.w.perms.set(`${t.stackTeam}:${t.stackUser}`, [])
    t.w.members.set(`${t.stackTeam}:${stranger}`, "Cy")
    t.w.perms.set(`${t.stackTeam}:${stranger}`, ["$delete_team"])
    expect((await deliver("team.updated", { id: t.stackTeam, display_name: "Acme" })).status).toBe(200)
    expect((await deleteInStack(t)).status).toBe(200)
    expect((await teamState(t.team)).team?.deleted_at).toBeTypeOf("number")
    expect(t.w.userVmPlanWrites).toEqual([])
    expect(await carried(t.team)).toMatchObject({ vm_plan: "max", outcome: "owner_unknown" })
  })
})
