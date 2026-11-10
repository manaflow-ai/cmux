import { describe, expect, it } from "vitest"
import { personalTeamIdFor, userIdFor } from "../src/domains/user.ts"
import { fireAlarm } from "./setup/alarm.ts"
import { deliver, mirroredTeam, PROJECT, teamState, teamStub, type World } from "./team-stack-support.ts"
import { inDO } from "./team-ssh-support.ts"

/**
 * Leo deleted a Stack team that carried its own operator Cloud grant (`cmuxVmPlan` on the Stack team
 * record), and the grant went with it: "i removed leo@cmux.com's team and so now it's just personal".
 * Stack's team.deleted names only the team id, so TeamDO keeps a copy of the grant from every team sync
 * and, when Stack confirms the delete, records it in the single owner's personal TeamDO. That TeamDO's
 * grant read (cloudVmPlan, which CloudDO calls) answers the higher of the person's own plan and the
 * carried grant. The sign-in service's records are never written, so no concurrent billing or operator
 * write can be lost, and an operator restriction on the person still wins.
 */

type Carried = { stack_team: string; vm_plan: string; outcome: string; owner: string | null; to_team: string | null }
const carried = (team: string) =>
  inDO(teamStub(team), async (_instance, state) => {
    const sql = state.storage.sql
    if (sql.exec(`SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'cloud_vm_plan_carried'`).toArray().length === 0) return null
    return (sql.exec(`SELECT stack_team, vm_plan, outcome, owner, to_team FROM cloud_vm_plan_carried`).toArray()[0] as Carried | undefined) ?? null
  })

/** The person's operator grant as CloudDO reads it: their personal TeamDO's cloudVmPlan, read fresh. */
const personalGrant = (w: World, stackUser: string) => {
  const team = personalTeamIdFor(userIdFor(PROJECT, stackUser))
  return inDO(teamStub(team), async (instance, state) => {
    instance.stack = w.fake
    state.storage.sql.exec(`CREATE TABLE IF NOT EXISTS cloud_vm_plan (id INTEGER PRIMARY KEY CHECK (id = 1), vm_plan TEXT, checked_at INTEGER NOT NULL)`)
    state.storage.sql.exec(`DELETE FROM cloud_vm_plan`)
    return instance.cloudVmPlan(team, stackUser)
  })
}

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
  it("records the deleted team's grant on its owner's personal team, whose grant read answers it", async () => {
    const t = await ownedTeamWithGrant("max")
    expect(await personalGrant(t.w, t.stackUser)).toEqual({ ok: true, vm_plan: null })
    expect((await deleteInStack(t)).status).toBe(200)
    expect((await teamState(t.team)).team?.deleted_at).toBeTypeOf("number")
    expect(await carried(t.team)).toEqual({ stack_team: t.stackTeam, vm_plan: "max", outcome: "moved", owner: t.user, to_team: personalTeamIdFor(t.user) })
    expect(await personalGrant(t.w, t.stackUser)).toEqual({ ok: true, vm_plan: "max" })
  })

  it("a Max owner stays Max: a lower carried grant never replaces their own plan", async () => {
    const t = await ownedTeamWithGrant("go")
    t.w.userPlans.set(t.stackUser, "max")
    expect((await deleteInStack(t)).status).toBe(200)
    // No override is answered, so the person's paid Max stands (cloudPlanId(max, null) = max).
    expect(await personalGrant(t.w, t.stackUser)).toEqual({ ok: true, vm_plan: null })
    t.w.userPlans.delete(t.stackUser)
    t.w.userVmPlans.set(t.stackUser, "max")
    expect(await personalGrant(t.w, t.stackUser)).toEqual({ ok: true, vm_plan: "max" })
  })

  it("an operator restriction on the person still wins over a carried grant", async () => {
    const t = await ownedTeamWithGrant("max")
    expect((await deleteInStack(t)).status).toBe(200)
    expect(await personalGrant(t.w, t.stackUser)).toEqual({ ok: true, vm_plan: "max" })
    t.w.userVmPlans.set(t.stackUser, "free")
    expect(await personalGrant(t.w, t.stackUser)).toEqual({ ok: true, vm_plan: "free" })
    t.w.userVmPlans.set(t.stackUser, "")
    expect(await personalGrant(t.w, t.stackUser)).toEqual({ ok: true, vm_plan: "" })
  })

  it("a billing write after the carry is never lost: the sign-in service is only read, and the read follows it", async () => {
    const t = await ownedTeamWithGrant("pro")
    t.w.userPlans.set(t.stackUser, "go")
    expect((await deleteInStack(t)).status).toBe(200)
    expect(await personalGrant(t.w, t.stackUser)).toEqual({ ok: true, vm_plan: "pro" })
    // Billing moves the person to Max: nothing the carry did overwrote it, and the grant read now keeps Max.
    t.w.userPlans.set(t.stackUser, "max")
    expect(await personalGrant(t.w, t.stackUser)).toEqual({ ok: true, vm_plan: null })
    expect(t.w.userPlans.get(t.stackUser)).toBe("max")
    expect(t.w.userVmPlans.has(t.stackUser)).toBe(false)
    expect("setUserVmPlan" in t.w.fake).toBe(false)
  })

  it("a higher carried grant raises an owner whose own plan or override is lower", async () => {
    const t = await ownedTeamWithGrant("max")
    t.w.userPlans.set(t.stackUser, "pro")
    t.w.userVmPlans.set(t.stackUser, "go")
    expect((await deleteInStack(t)).status).toBe(200)
    expect(await personalGrant(t.w, t.stackUser)).toEqual({ ok: true, vm_plan: "max" })
  })

  it("records nothing for a team without a grant", async () => {
    const t = await ownedTeamWithGrant(null)
    expect((await deleteInStack(t)).status).toBe(200)
    expect((await teamState(t.team)).team?.deleted_at).toBeTypeOf("number")
    expect(await carried(t.team)).toBeNull()
    expect(await personalGrant(t.w, t.stackUser)).toEqual({ ok: true, vm_plan: null })
  })

  it("with two owners it moves nothing, keeps the grant on record for an operator, and still deletes the team", async () => {
    const t = await ownedTeamWithGrant("max")
    const second = crypto.randomUUID()
    t.w.members.set(`${t.stackTeam}:${second}`, "Bea")
    t.w.perms.set(`${t.stackTeam}:${second}`, ["$delete_team"])
    expect((await deliver("team.updated", { id: t.stackTeam, display_name: "Acme" })).status).toBe(200)
    expect((await deleteInStack(t)).status).toBe(200)
    expect((await teamState(t.team)).team?.deleted_at).toBeTypeOf("number")
    expect(await carried(t.team)).toMatchObject({ vm_plan: "max", outcome: "no_single_owner", owner: null, to_team: null })
    expect(await personalGrant(t.w, t.stackUser)).toEqual({ ok: true, vm_plan: null })
    expect(await personalGrant(t.w, second)).toEqual({ ok: true, vm_plan: null })
  })

  it("an owner who never signed in to cmux still gets the grant on their personal team", async () => {
    const t = await ownedTeamWithGrant("max")
    const stranger = crypto.randomUUID()
    t.w.perms.set(`${t.stackTeam}:${t.stackUser}`, [])
    t.w.members.set(`${t.stackTeam}:${stranger}`, "Cy")
    t.w.perms.set(`${t.stackTeam}:${stranger}`, ["$delete_team"])
    expect((await deliver("team.updated", { id: t.stackTeam, display_name: "Acme" })).status).toBe(200)
    expect((await deleteInStack(t)).status).toBe(200)
    expect((await carried(t.team))?.outcome).toBe("moved")
    expect(await personalGrant(t.w, stranger)).toEqual({ ok: true, vm_plan: "max" })
    expect(await personalGrant(t.w, t.stackUser)).toEqual({ ok: true, vm_plan: null })
  })

  it("a delete confirmed only on its re-check still carries the grant", async () => {
    const t = await ownedTeamWithGrant("max")
    // Stack still lists the team: the delete waits for a re-check (whose synthetic key once passed 128 characters).
    expect((await deliver("team.deleted", { id: t.stackTeam })).body).toMatchObject({ ok: true, outcome: "team_delete_pending" })
    t.w.teams.delete(t.stackTeam)
    t.w.vmPlans.delete(t.stackTeam)
    await inDO(teamStub(t.team), async (_instance, state) => {
      state.storage.sql.exec(`UPDATE stack_team_recheck SET due_at = 0`)
    })
    await fireAlarm(teamStub(t.team))
    expect((await teamState(t.team)).team?.deleted_at).toBeTypeOf("number")
    expect((await carried(t.team))?.outcome).toBe("moved")
    expect(await personalGrant(t.w, t.stackUser)).toEqual({ ok: true, vm_plan: "max" })
  })

  // Review F3: a grant read that finds the team already gone keeps the copy a delete carries.
  it("a stale grant refresh after the team is gone in Stack keeps the copy, and the delete still carries it", async () => {
    const t = await ownedTeamWithGrant("max")
    t.w.teams.delete(t.stackTeam)
    t.w.vmPlans.delete(t.stackTeam)
    await inDO(teamStub(t.team), async (instance, state) => {
      state.storage.sql.exec(`UPDATE cloud_vm_plan SET checked_at = 0`)
      expect(await instance.cloudVmPlan(t.team)).toEqual({ ok: true, vm_plan: "max" })
    })
    expect((await deliver("team.deleted", { id: t.stackTeam })).status).toBe(200)
    expect((await carried(t.team))?.outcome).toBe("moved")
    expect(await personalGrant(t.w, t.stackUser)).toEqual({ ok: true, vm_plan: "max" })
  })
})
