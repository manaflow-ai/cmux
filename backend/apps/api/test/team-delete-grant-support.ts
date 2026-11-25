import { expect, vi } from "vitest"
import { personalTeamIdFor, userIdFor } from "../src/domains/user.ts"
import { fireAlarm } from "./setup/alarm.ts"
import { deliver, mirroredTeam, PROJECT, teamStub, type World } from "./team-stack-support.ts"
import { inDO } from "./team-ssh-support.ts"

/**
 * What team-delete-keeps-grant.test.ts and the grant carry property (team-delete-grant-property-*.test.ts)
 * share. The property's 64 seeded interleavings run as 4 files of 16, so vitest runs them in parallel: one
 * file of 64 needed about 160 s on an idle runner but 270 s and more on a loaded one, and failed its own
 * time limit there (backend runs 44696426698 and 44718286415: only 62 and 60 of 64 ran).
 */

export type Carried = { stack_team: string; vm_plan: string; outcome: string; owner: string | null; to_team: string | null }
export const carried = (team: string) =>
  inDO(teamStub(team), async (_instance, state) => {
    const sql = state.storage.sql
    if (sql.exec(`SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'cloud_vm_plan_carried'`).toArray().length === 0) return null
    return (sql.exec(`SELECT stack_team, vm_plan, outcome, owner, to_team FROM cloud_vm_plan_carried`).toArray()[0] as Carried | undefined) ?? null
  })

/** The person's operator grant as CloudDO reads it: their personal TeamDO's cloudVmPlan, read fresh. */
export const personalGrant = (w: World, stackUser: string) => {
  const team = personalTeamIdFor(userIdFor(PROJECT, stackUser))
  return inDO(teamStub(team), async (instance, state) => {
    instance.stack = w.fake
    state.storage.sql.exec(`CREATE TABLE IF NOT EXISTS cloud_vm_plan (id INTEGER PRIMARY KEY CHECK (id = 1), vm_plan TEXT, checked_at INTEGER NOT NULL)`)
    state.storage.sql.exec(`DELETE FROM cloud_vm_plan`)
    return instance.cloudVmPlan(team, stackUser)
  })
}

/** The same read without clearing TeamDO's cached answer (review F2 at 28f85c71: a cache must not hide a paid upgrade). */
export const personalGrantCached = (w: World, stackUser: string) => {
  const team = personalTeamIdFor(userIdFor(PROJECT, stackUser))
  return inDO(teamStub(team), async (instance) => {
    instance.stack = w.fake
    return instance.cloudVmPlan(team, stackUser)
  })
}

/** The model router's plan refresh of the shared team (TeamDO.inferencePlan), with its plan copy made stale first. */
export const planRefresh = (team: string, user: string) =>
  inDO(teamStub(team), async (instance, state) => {
    state.storage.sql.exec(`CREATE TABLE IF NOT EXISTS inference_plan (id INTEGER PRIMARY KEY CHECK (id = 1), plan TEXT, checked_at INTEGER NOT NULL, failed_at INTEGER)`)
    state.storage.sql.exec(`DELETE FROM inference_plan`)
    return instance.inferencePlan(team, user)
  })

/** Makes the shared team's delivery to the personal TeamDO fail (`fail` = true) or work again (false). */
export const personalUnreachable = (team: string, fail: boolean) =>
  inDO(teamStub(team), async (instance) => {
    instance.carryTo = fail
      ? async () => {
          throw new Error("TeamDO unreachable")
        }
      : undefined
  })
export const carriedRow = (team: string) =>
  inDO(teamStub(team), async (_instance, state) => state.storage.sql.exec<{ outcome: string; fails: number }>(`SELECT outcome, fails FROM cloud_vm_plan_carried`).toArray()[0] ?? null)
export const makeCarryDue = (team: string) =>
  inDO(teamStub(team), async (_instance, state) => {
    state.storage.sql.exec(`UPDATE cloud_vm_plan_carried SET due_at = 0`)
  })

/** A mirrored Stack team whose one member owns it, with `grant` on its Stack record, synced so TeamDO has read it. */
export const ownedTeamWithGrant = async (grant: string | null) => {
  const t = await mirroredTeam()
  t.w.perms.set(`${t.stackTeam}:${t.stackUser}`, ["$delete_team"])
  if (grant !== null) t.w.vmPlans.set(t.stackTeam, grant)
  expect((await deliver("team.updated", { id: t.stackTeam, display_name: "Acme" })).status).toBe(200)
  return t
}

export const deleteInStack = async (t: Awaited<ReturnType<typeof mirroredTeam>>) => {
  t.w.teams.delete(t.stackTeam)
  t.w.vmPlans.delete(t.stackTeam)
  return deliver("team.deleted", { id: t.stackTeam })
}

/** The next team read answers what Stack holds now, then waits until released (a slow, older read). */
export const gatedTeamRead = (w: World) => {
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
export const rng = (seed: number) => () => {
  seed = (seed + 0x6d2b79f5) | 0
  let x = Math.imul(seed ^ (seed >>> 15), 1 | seed)
  x = (x + Math.imul(x ^ (x >>> 7), 61 | x)) ^ x
  return ((x ^ (x >>> 14)) >>> 0) / 4294967296
}

/** The interleavings with seeds 1000 + from .. 1000 + from + count - 1, each checked against what Stack holds last. */
export const grantCarryProperty = async (from: number, count: number) => {
    const grants = ["max", "pro", "go", "free", null] as const
    let carriedRuns = 0
    const began = performance.now()
    for (let run = from; run < from + count; run++) {
      // Fail plainly before the test's timeout, so the loop never outlives the test and slows the files after it.
      if (performance.now() - began > 270_000) throw new Error(`only ${run - from} of ${count} interleavings (seeds ${1000 + from}..${999 + from + count}) ran in 270 s`)
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
    console.log(JSON.stringify({ msg: "grant carry property", from, runs: count, carried: carriedRuns }))
}
