import { describe, expect, it, vi } from "vitest"
import { personalTeamIdFor, userIdFor } from "../src/domains/user.ts"
import { fireAlarm } from "./setup/alarm.ts"
import { call, deliver, memberRow, mirroredTeam, PROJECT, teamState, teamStub, type World } from "./team-stack-support.ts"
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

/** The same read without clearing TeamDO's cached answer (review F2 at 28f85c71: a cache must not hide a paid upgrade). */
const personalGrantCached = (w: World, stackUser: string) => {
  const team = personalTeamIdFor(userIdFor(PROJECT, stackUser))
  return inDO(teamStub(team), async (instance) => {
    instance.stack = w.fake
    return instance.cloudVmPlan(team, stackUser)
  })
}

/** The model router's plan refresh of the shared team (TeamDO.inferencePlan), with its plan copy made stale first. */
const planRefresh = (team: string, user: string) =>
  inDO(teamStub(team), async (instance, state) => {
    state.storage.sql.exec(`CREATE TABLE IF NOT EXISTS inference_plan (id INTEGER PRIMARY KEY CHECK (id = 1), plan TEXT, checked_at INTEGER NOT NULL, failed_at INTEGER)`)
    state.storage.sql.exec(`DELETE FROM inference_plan`)
    return instance.inferencePlan(team, user)
  })

/** Makes the shared team's delivery to the personal TeamDO fail (`fail` = true) or work again (false). */
const personalUnreachable = (team: string, fail: boolean) =>
  inDO(teamStub(team), async (instance) => {
    instance.carryTo = fail
      ? async () => {
          throw new Error("TeamDO unreachable")
        }
      : undefined
  })
const carriedRow = (team: string) =>
  inDO(teamStub(team), async (_instance, state) => state.storage.sql.exec<{ outcome: string; fails: number }>(`SELECT outcome, fails FROM cloud_vm_plan_carried`).toArray()[0] ?? null)
const makeCarryDue = (team: string) =>
  inDO(teamStub(team), async (_instance, state) => {
    state.storage.sql.exec(`UPDATE cloud_vm_plan_carried SET due_at = 0`)
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

/** The next team read answers what Stack holds now, then waits until released (a slow, older read). */
const gatedTeamRead = (w: World) => {
  const real = w.fake.getTeam
  let enter!: () => void
  let release!: () => void
  // A read that never comes fails in 5 s instead of hanging the suite.
  const entered = Promise.race([
    new Promise<void>((r) => (enter = r)),
    new Promise<void>((_r, reject) => setTimeout(() => reject(new Error("the gated team read never started")), 5_000))
  ])
  const released = new Promise<void>((r) => (release = r))
  w.fake.getTeam = async (team: string) => {
    w.fake.getTeam = real
    const answer = await real(team)
    enter()
    await released
    return answer
  }
  return { entered, release }
}

/** A small seeded generator (mulberry32), so a failing interleaving is replayed from its seed. */
const rng = (seed: number) => () => {
  seed = (seed + 0x6d2b79f5) | 0
  let x = Math.imul(seed ^ (seed >>> 15), 1 | seed)
  x = (x + Math.imul(x ^ (x >>> 7), 61 | x)) ^ x
  return ((x ^ (x >>> 14)) >>> 0) / 4294967296
}

// Each interleaving builds a fresh team (about 1 s alone, 2.5 s beside the suite's other files), so 64 fit the timeout.
const RUNS = 64
describe("property: a carry never grants more than the latest confirmed grant, or to anyone but the latest owner", { timeout: 300_000 }, () => {
  it(`${RUNS} random interleavings of refreshes, webhooks, ownership changes, revocations and deletes`, async () => {
    const grants = ["max", "pro", "go", "free", null] as const
    let carriedRuns = 0
    const began = performance.now()
    for (let run = 0; run < RUNS; run++) {
      // Fail plainly before the test's timeout, so the loop never outlives the test and slows the files after it.
      if (performance.now() - began > 270_000) throw new Error(`only ${run} of ${RUNS} interleavings ran in 270 s`)
      const seed = 1000 + run
      const r = rng(seed)
      const pick = <T>(xs: ReadonlyArray<T>) => xs[Math.floor(r() * xs.length)]!
      // Half the runs freeze the clock, so every read and write collides in one millisecond.
      const clock = r() < 0.5 ? vi.spyOn(Date, "now").mockReturnValue(Date.now()) : null
      const log: Array<string> = []
      let quiet: string | null = null
      try {
        const t = await ownedTeamWithGrant("max")
        quiet = t.team
        const alice = t.stackUser
        const bob = crypto.randomUUID()
        t.w.members.set(`${t.stackTeam}:${bob}`, "Bob")
        expect((await deliver("team.updated", { id: t.stackTeam, display_name: "Acme" })).status).toBe(200)
        let owner = alice
        let slow: { release: () => void; done: Promise<unknown> } | null = null
        const pace = (on: boolean) =>
          inDO(teamStub(t.team), async (instance) => {
            instance.stackPace = on ? undefined : async () => false
          })
        /** One event: delivered now, delayed behind the pace, or with failing member reads. */
        const send = async (type: string, data: unknown) => {
          const how = pick(["now", "now", "delayed", "failing"] as const)
          log.push(`${type}:${how}`)
          if (how === "delayed") await pace(false)
          const real = t.w.fake.getTeamMember
          if (how === "failing")
            t.w.fake.getTeamMember = async () => {
              throw new Error("stack GET team member returned 503")
            }
          try {
            await deliver(type, data)
          } finally {
            t.w.fake.getTeamMember = real
            if (how === "delayed") await pace(true)
          }
        }
        const steps = 3 + Math.floor(r() * 6)
        for (let i = 0; i < steps; i++) {
          const op = pick(["grant", "grant", "owner", "refresh", "slow", "alarm", "plan"] as const)
          log.push(op)
          if (op === "grant") {
            const g = pick(grants)
            if (g === null) t.w.vmPlans.delete(t.stackTeam)
            else t.w.vmPlans.set(t.stackTeam, g)
            log.push(`=${g}`)
            await send("team.updated", { id: t.stackTeam, display_name: "Acme" })
          } else if (op === "plan") {
            // Review F1 at f2d36575: the grant changes and the model router's plan refresh reads it before any webhook.
            const g = pick(grants)
            if (g === null) t.w.vmPlans.delete(t.stackTeam)
            else t.w.vmPlans.set(t.stackTeam, g)
            log.push(`=${g}`)
            await planRefresh(t.team, t.user)
          } else if (op === "owner") {
            const next = owner === alice ? bob : alice
            t.w.perms.set(`${t.stackTeam}:${next}`, ["$delete_team"])
            t.w.perms.set(`${t.stackTeam}:${owner}`, [])
            const prev = owner
            owner = next
            // Stack sends one event per member; either may come first, and the demotion may not have come yet.
            const events = [
              ["team_permission.created", { id: "$delete_team", team_id: t.stackTeam, user_id: next }],
              ["team_permission.deleted", { id: "$delete_team", team_id: t.stackTeam, user_id: prev }]
            ] as const
            const order = r() < 0.5 ? [events[0]] : r() < 0.5 ? [events[0], events[1]] : [events[1], events[0]]
            for (const [type, data] of order) await send(type, data)
          } else if (op === "refresh" || (op === "slow" && slow !== null)) {
            await inDO(teamStub(t.team), async (instance, state) => {
              state.storage.sql.exec(`UPDATE cloud_vm_plan SET checked_at = 0`)
              return instance.cloudVmPlan(t.team)
            })
          } else if (op === "slow") {
            const gate = gatedTeamRead(t.w)
            const done = inDO(teamStub(t.team), async (instance, state) => {
              state.storage.sql.exec(`UPDATE cloud_vm_plan SET checked_at = 0`)
              return instance.cloudVmPlan(t.team)
            })
            await gate.entered
            slow = { release: gate.release, done }
          } else {
            await inDO(teamStub(t.team), async (_instance, state) => {
              state.storage.sql.exec(`UPDATE stack_team_recheck SET due_at = 0 WHERE type != 'team.deleted'`)
            })
            await fireAlarm(teamStub(t.team))
          }
          // A slow refresh started earlier finishes after this step's reads.
          if (slow !== null && op !== "slow") {
            slow.release()
            await slow.done
            slow = null
          }
        }
        if (slow !== null) {
          slow.release()
          await slow.done
        }
        // The truth when the team is deleted: the latest grant and owner Stack holds.
        const truthGrant = t.w.vmPlans.get(t.stackTeam) ?? null
        expect((await deleteInStack(t)).status).toBe(200)
        const c = await carried(t.team)
        const context = `seed ${seed}: ${log.join(" ")} -> ${JSON.stringify(c)} (truth ${truthGrant} to ${owner === alice ? "alice" : "bob"})`
        if (c?.outcome === "moved") {
          carriedRuns++
          expect(c.vm_plan, context).toBe(truthGrant)
          expect(c.owner, context).toBe(userIdFor(PROJECT, owner))
        }
        const other = owner === alice ? bob : alice
        expect(await personalGrant(t.w, other), context).toEqual({ ok: true, vm_plan: null })
        const mine = await personalGrant(t.w, owner)
        if (mine.ok && mine.vm_plan !== null) expect(mine.vm_plan, context).toBe(truthGrant)
      } finally {
        clock?.mockRestore()
        // The run's team keeps no waiting re-check and no alarm: earlier runs' teams must not keep waking
        // (each wake reads the fake Stack) and slow every later run, or outlive the test.
        if (quiet !== null)
          await inDO(teamStub(quiet), async (_instance, state) => {
            state.storage.sql.exec(`DELETE FROM stack_team_recheck`)
            await state.storage.deleteAlarm()
          })
      }
    }
    console.log(JSON.stringify({ msg: "grant carry property", runs: RUNS, carried: carriedRuns }))
  })
})
