import { describe, expect, it, vi } from "vitest"
import { personalTeamIdFor, userIdFor } from "../src/domains/user.ts"
import { fireAlarm } from "./setup/alarm.ts"
import { carried, carriedRow, deleteInStack, gatedTeamRead, makeCarryDue, ownedTeamWithGrant, personalGrant, personalGrantCached, personalUnreachable, planRefresh } from "./team-delete-grant-support.ts"
import { call, deliver, memberRow, mirroredTeam, PROJECT, teamState, teamStub } from "./team-stack-support.ts"
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

  it("a deleted team's cmux NEXT grant is carried like a classic one, and ranks against the owner's grant", async () => {
    const t = await ownedTeamWithGrant("next_max")
    t.w.userVmPlans.set(t.stackUser, "pro")
    expect((await deleteInStack(t)).status).toBe(200)
    expect((await carried(t.team))?.vm_plan).toBe("next_max")
    expect(await personalGrant(t.w, t.stackUser)).toEqual({ ok: true, vm_plan: "next_max" })
    t.w.userVmPlans.set(t.stackUser, "max")
    expect(await personalGrant(t.w, t.stackUser)).toEqual({ ok: true, vm_plan: "max" })
  })

  it("a carried classic Max never replaces an own next_pro grant of a cmux NEXT Max subscriber", async () => {
    const t = await ownedTeamWithGrant("max")
    t.w.userPlans.set(t.stackUser, "pro")
    t.w.userNextPlans.set(t.stackUser, "next_max")
    t.w.userVmPlans.set(t.stackUser, "next_pro")
    expect((await deleteInStack(t)).status).toBe(200)
    expect(await personalGrant(t.w, t.stackUser)).toEqual({ ok: true, vm_plan: "next_pro" })
    // Without the NEXT subscription the carried Max is higher than everything the person holds.
    t.w.userNextPlans.delete(t.stackUser)
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

  // Review F1 at 28f85c71: the carry never holds up the delete or the revocation of members' access.
  it("an unreachable personal TeamDO: the tombstone commits, access is revoked at once, and the pending carry is delivered on retry", async () => {
    const t = await ownedTeamWithGrant("max")
    await personalUnreachable(t.team, true)
    const r = await deleteInStack(t)
    expect(r.body).toMatchObject({ ok: true, outcome: "team_deleted" })
    expect((await teamState(t.team)).team?.deleted_at).toBeTypeOf("number")
    await fireAlarm(teamStub(t.team))
    await fireAlarm(teamStub(t.team))
    expect(await memberRow(t.team, t.user)).toBeNull()
    const denied = await call(t.token, "/v1/read", { op: "team_vm.status", params: {} }, t.team)
    expect(denied.status).toBe(403)
    expect(await carriedRow(t.team)).toMatchObject({ outcome: "pending" })
    expect(await personalGrant(t.w, t.stackUser)).toEqual({ ok: true, vm_plan: null })
    await personalUnreachable(t.team, false)
    await makeCarryDue(t.team)
    await fireAlarm(teamStub(t.team))
    expect(await carriedRow(t.team)).toMatchObject({ outcome: "moved" })
    expect(await personalGrant(t.w, t.stackUser)).toEqual({ ok: true, vm_plan: "max" })
  })

  it("a carry that keeps failing never undoes or blocks the delete", async () => {
    const t = await ownedTeamWithGrant("max")
    await personalUnreachable(t.team, true)
    expect((await deleteInStack(t)).body).toMatchObject({ ok: true, outcome: "team_deleted" })
    for (let i = 0; i < 4; i++) {
      await makeCarryDue(t.team)
      await fireAlarm(teamStub(t.team))
    }
    expect((await teamState(t.team)).team?.deleted_at).toBeTypeOf("number")
    expect(await memberRow(t.team, t.user)).toBeNull()
    const row = await carriedRow(t.team)
    expect(row?.outcome).toBe("pending")
    expect(row?.fails).toBeGreaterThanOrEqual(4)
    // A later team event for the deleted team changes nothing.
    expect((await deliver("team.deleted", { id: t.stackTeam })).status).toBe(200)
    expect((await teamState(t.team)).team?.deleted_at).toBeTypeOf("number")
  })

  // Review F2 at 28f85c71: a carried grant answered from TeamDO's cache never hides a paid upgrade.
  it("a paid upgrade after the carry is answered at once, never hidden by a cached carried grant", async () => {
    const t = await ownedTeamWithGrant("go")
    expect((await deleteInStack(t)).status).toBe(200)
    expect(await personalGrantCached(t.w, t.stackUser)).toEqual({ ok: true, vm_plan: "go" })
    t.w.userPlans.set(t.stackUser, "max")
    expect(await personalGrantCached(t.w, t.stackUser)).toEqual({ ok: true, vm_plan: null })
  })

  // Review F1 at e9544f44, and its class: a carry always uses the latest grant observed, never a stale copy.
  it("a grant revoked to free before an unconfirmed delete is what the confirmed delete sees: nothing is carried", async () => {
    const t = await ownedTeamWithGrant("max")
    t.w.vmPlans.set(t.stackTeam, "free")
    expect((await deliver("team.deleted", { id: t.stackTeam })).body).toMatchObject({ ok: true, outcome: "team_delete_pending" })
    t.w.teams.delete(t.stackTeam)
    t.w.vmPlans.delete(t.stackTeam)
    await inDO(teamStub(t.team), async (_instance, state) => {
      state.storage.sql.exec(`UPDATE stack_team_recheck SET due_at = 0`)
    })
    await fireAlarm(teamStub(t.team))
    expect((await teamState(t.team)).team?.deleted_at).toBeTypeOf("number")
    expect(await carried(t.team)).toBeNull()
    expect(await personalGrant(t.w, t.stackUser)).toEqual({ ok: true, vm_plan: null })
  })

  it("a sync that stopped early (a member read found the team gone) leaves the owner unconfirmed: nothing is carried", async () => {
    const t = await ownedTeamWithGrant("max")
    t.w.vmPlans.set(t.stackTeam, "go")
    const real = t.w.fake.getTeamMember
    t.w.fake.getTeamMember = async () => "team_gone" as const
    expect((await deliver("team_membership.created", { team_id: t.stackTeam, user_id: t.stackUser })).body).toMatchObject({ ok: true, outcome: "team_missing_recheck" })
    t.w.fake.getTeamMember = real
    expect((await deleteInStack(t)).status).toBe(200)
    expect(await carried(t.team)).toMatchObject({ vm_plan: "go", outcome: "unverified", to_team: null })
    expect(await personalGrant(t.w, t.stackUser)).toEqual({ ok: true, vm_plan: null })
  })

  it("a team event still waiting when the delete is confirmed may carry a newer grant: nothing is carried, an operator decides", async () => {
    const t = await ownedTeamWithGrant("max")
    t.w.vmPlans.set(t.stackTeam, "free")
    // The revocation's team.updated waits for the shared pace, so the copy still says max.
    await inDO(teamStub(t.team), async (instance) => {
      instance.stackPace = async () => false
    })
    expect((await deliver("team.updated", { id: t.stackTeam, display_name: "Acme" })).body).toMatchObject({ ok: true, outcome: "queued" })
    await inDO(teamStub(t.team), async (instance) => {
      instance.stackPace = undefined
    })
    expect((await deleteInStack(t)).body).toMatchObject({ ok: true, outcome: "team_deleted" })
    expect(await carried(t.team)).toMatchObject({ vm_plan: "max", outcome: "unverified", to_team: null })
    expect(await personalGrant(t.w, t.stackUser)).toEqual({ ok: true, vm_plan: null })
  })

  it("a team grant that grants no paid limits is never carried", async () => {
    const t = await ownedTeamWithGrant("enterprise")
    expect((await deleteInStack(t)).status).toBe(200)
    expect(await carried(t.team)).toBeNull()
  })

  // Review F2 at e9544f44: an override the carried grant cannot exceed is answered without the paid-plan read.
  it("an owner override at least the carried grant is answered even when the paid-plan read fails", async () => {
    const t = await ownedTeamWithGrant("go")
    expect((await deleteInStack(t)).status).toBe(200)
    t.w.userVmPlans.set(t.stackUser, "max")
    t.w.fake.getUserPlan = async () => {
      throw new Error("stack GET user returned 429")
    }
    expect(await personalGrant(t.w, t.stackUser)).toEqual({ ok: true, vm_plan: "max" })
  })

  // Review F1 at 38b48ba9: ownership moved, and the membership read that would show it failed.
  it("ownership moved from Alice to Bob, the member read failed: the grant goes to neither", async () => {
    const t = await ownedTeamWithGrant("max")
    const bob = crypto.randomUUID()
    t.w.members.set(`${t.stackTeam}:${bob}`, "Bob")
    expect((await deliver("team.updated", { id: t.stackTeam, display_name: "Acme" })).status).toBe(200)
    t.w.perms.set(`${t.stackTeam}:${bob}`, ["$delete_team"])
    t.w.perms.set(`${t.stackTeam}:${t.stackUser}`, [])
    const real = t.w.fake.getTeamMember
    t.w.fake.getTeamMember = async () => {
      throw new Error("stack GET team member returned 503")
    }
    expect((await deliver("team_permission.created", { id: "$delete_team", team_id: t.stackTeam, user_id: bob })).body).toMatchObject({ ok: true, outcome: "queued" })
    t.w.fake.getTeamMember = real
    expect((await deleteInStack(t)).status).toBe(200)
    expect(await carried(t.team)).toMatchObject({ outcome: "unverified", to_team: null })
    expect(await personalGrant(t.w, t.stackUser)).toEqual({ ok: true, vm_plan: null })
    expect(await personalGrant(t.w, bob)).toEqual({ ok: true, vm_plan: null })
  })

  // Review F2 at 38b48ba9: an older refresh that finishes last, in the same millisecond, never restores a revoked grant.
  it("an older grant refresh finishing after a newer webhook read, same millisecond, never restores the revoked grant", async () => {
    const t = await ownedTeamWithGrant("max")
    const clock = vi.spyOn(Date, "now").mockReturnValue(Date.now())
    try {
      const gate = gatedTeamRead(t.w)
      const refresh = inDO(teamStub(t.team), async (instance, state) => {
        state.storage.sql.exec(`UPDATE cloud_vm_plan SET checked_at = 0`)
        return instance.cloudVmPlan(t.team)
      })
      await gate.entered
      t.w.vmPlans.set(t.stackTeam, "free")
      expect((await deliver("team.updated", { id: t.stackTeam, display_name: "Acme" })).status).toBe(200)
      gate.release()
      await refresh
    } finally {
      clock.mockRestore()
    }
    expect((await deleteInStack(t)).status).toBe(200)
    expect(await carried(t.team)).toBeNull()
    expect(await personalGrant(t.w, t.stackUser)).toEqual({ ok: true, vm_plan: null })
  })

  // Review F1 at f2d36575, and its class: every read of the team record feeds the grant copy a delete carries.
  it("a grant upgrade seen by a plan refresh before its webhook arrives is what the delete carries", async () => {
    const t = await ownedTeamWithGrant("go")
    // Max is set on the team record; its team.updated has not arrived when the model router refreshes the plan.
    t.w.vmPlans.set(t.stackTeam, "max")
    expect(await planRefresh(t.team, t.user)).toMatchObject({ ok: true })
    expect((await deleteInStack(t)).status).toBe(200)
    expect(await carried(t.team)).toMatchObject({ vm_plan: "max", outcome: "moved", owner: t.user })
    expect(await personalGrant(t.w, t.stackUser)).toEqual({ ok: true, vm_plan: "max" })
  })

  // Review F2 at f2d36575: an override that was read stays the answer when only the paid-plan read fails.
  it("an override below the carried grant is answered when the paid-plan read fails, with or without a cached answer", async () => {
    const t = await ownedTeamWithGrant("max")
    expect((await deleteInStack(t)).status).toBe(200)
    t.w.userVmPlans.set(t.stackUser, "pro")
    const real = t.w.fake.getUserPlan
    const failing = async () => {
      throw new Error("stack GET user returned 429")
    }
    t.w.fake.getUserPlan = failing
    // No cached answer: Pro is confirmed, so the answer is Pro, never unavailable.
    expect(await personalGrant(t.w, t.stackUser)).toEqual({ ok: true, vm_plan: "pro" })
    t.w.fake.getUserPlan = real
    expect(await personalGrantCached(t.w, t.stackUser)).toEqual({ ok: true, vm_plan: "max" })
    // With the carried Max answered last, a failed paid-plan read keeps it rather than lowering the person to Pro.
    t.w.fake.getUserPlan = failing
    expect(await personalGrantCached(t.w, t.stackUser)).toEqual({ ok: true, vm_plan: "max" })
  })
})
