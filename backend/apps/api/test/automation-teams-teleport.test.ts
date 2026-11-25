import { env } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import type { Principal } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { nextFire } from "../src/cron.ts"
import { personalTeamIdFor } from "../src/domains/user.ts"
import { principalForOwner } from "../src/team-select.ts"
import { cloudTestUser } from "./setup/cloud-teams.ts"

// docs/automations-teleport-teams.md: team permissions and audit (section 4), the catch-up policy
// and time zones (section 3) and the single-writer teleport handoff (section 2), at the SchedulerDO.

const ns = (env as unknown as { SCHEDULER_DO: DurableObjectNamespace }).SCHEDULER_DO
type Frame = { t: string; value?: any; code?: string; message?: string; replayed?: boolean }
type Stub = {
  submit(entity: string, p: Principal, frame: unknown): Promise<{ frames: Array<Frame> }>
  readOp(entity: string, p: Principal, op: string, params: unknown): Promise<{ ok: boolean; value?: any; code?: string }>
}
const stub = (team: string) => ns.get(ns.idFromName(team)) as unknown as Stub
interface Internals {
  submitSystem(op: string, params: unknown, key: string): { frames: Array<Frame> }
  onWake(now: number): Promise<void>
}
const inScheduler = (team: string, fn: (s: Internals) => Promise<void>) =>
  (runInDurableObject as unknown as (stub: unknown, cb: (instance: unknown) => Promise<void>) => Promise<void>)(ns.get(ns.idFromName(team)), (i) => fn(i as Internals))

let seq = 0
const newTeam = () => `team_a908${Date.now().toString(16).slice(-9).padStart(9, "0")}${(++seq).toString(16).padStart(7, "0")}`
// Users 191..199 of the allowlisted test users.
let userSeq = 190
const member = (team: string, team_role?: string): Principal & { user: string } => {
  const user = cloudTestUser(++userSeq > 199 ? (userSeq = 191) : userSeq)
  return { identity: `user:${user}`, user, team, kind: "session", ...(team_role ? { team_role } : {}) } as Principal & { user: string }
}
const answer = (r: { frames: Array<Frame> }) => r.frames.find((f) => f.t === "result" || f.t === "reject")!
const op = async (team: string, p: Principal, name: string, params: unknown, key: string = crypto.randomUUID()) =>
  answer(await stub(team).submit(team, p, { t: "op", op: name, params, idempotency_key: key, origin: "user" }))
const read = (team: string, p: Principal, name: string, params: unknown = {}) => stub(team).readOp(team, p, name, params)
const BODY_TEXT = "a908-body-text-never-in-audit"
const steps = { type: "steps", steps: [{ type: "note", text: BODY_TEXT }] }
const create = (team: string, p: Principal, extra: Record<string, unknown> = {}) =>
  op(team, p, "automation.create", { name: "job", triggers: [{ type: "manual" }], body: steps, ...extra })
const allowRuns = (team: string) => inScheduler(team, async (s) => void s.submitSystem("scheduler.run_policy", { version: 1, runs_allowed: true }, `test-policy:${team}`))
const handoffId = () => `tp_${crypto.randomUUID().replaceAll("-", "")}`
const HOUR = 3600_000

describe("team automations: who may view, edit and run", () => {
  it("a private automation is invisible to other members (not_found, not forbidden) and visible to admins", async () => {
    const team = newTeam()
    const alice = member(team, "member")
    const bob = member(team, "member")
    const ada = member(team, "admin")
    const made = await create(team, alice, { sharing: "private" })
    expect(made.t).toBe("result")
    expect(made.value.sharing).toBe("private")
    const id = made.value.id as string
    const bobList = await read(team, bob, "automation.list")
    expect(bobList.value.automations.map((a: any) => a.id)).not.toContain(id)
    expect((await read(team, bob, "automation.get", { automation: id })).code).toBe("selector.not_found")
    expect((await op(team, bob, "automation.update", { automation: id, enabled: false })).code).toBe("selector.not_found")
    expect((await op(team, bob, "automation.delete", { automation: id })).code).toBe("selector.not_found")
    expect((await read(team, bob, "automation.runs.list", { automation: id })).value?.runs ?? []).toEqual([])
    expect((await read(team, ada, "automation.list")).value.automations.map((a: any) => a.id)).toContain(id)
    expect((await read(team, alice, "automation.get", { automation: id })).ok).toBe(true)
  })

  it("a team automation: members view and run it; only its creator, editors and admins change it", async () => {
    const team = newTeam()
    const alice = member(team, "member")
    const bob = member(team, "member")
    const ada = member(team, "admin")
    const made = await create(team, alice)
    expect(made.value.sharing).toBe("team")
    const id = made.value.id as string
    expect((await read(team, bob, "automation.get", { automation: id })).ok).toBe(true)
    expect((await op(team, bob, "automation.update", { automation: id, enabled: false })).code).toBe("auth.forbidden")
    expect((await op(team, bob, "automation.delete", { automation: id })).code).toBe("auth.forbidden")
    expect((await op(team, ada, "automation.update", { automation: id, enabled: false })).t).toBe("result")
    expect((await op(team, alice, "automation.update", { automation: id, editors: [bob.user] })).t).toBe("result")
    expect((await op(team, bob, "automation.update", { automation: id, enabled: true })).t).toBe("result")
    // An editor changes the job, never who may change it or who sees it.
    expect((await op(team, bob, "automation.update", { automation: id, sharing: "private" })).code).toBe("auth.forbidden")
    expect((await op(team, bob, "automation.update", { automation: id, editors: [] })).code).toBe("auth.forbidden")
    await allowRuns(team)
    const carol = member(team, "member")
    expect((await op(team, carol, "automation.run", { automation: id })).t).toBe("result")
  })

  it("a shared-team principal without a role is a member, never an admin", async () => {
    const team = newTeam()
    const alice = member(team, "member")
    const nobody = member(team)
    const id = (await create(team, alice)).value.id as string
    expect((await op(team, nobody, "automation.update", { automation: id, enabled: false })).code).toBe("auth.forbidden")
  })

  it("in a personal team the user is the owner without a role", async () => {
    const solo = member("team_00000000000000000000")
    const team = personalTeamIdFor(solo.user)
    const p = { ...solo, team }
    const id = (await create(team, p, { sharing: "private" })).value.id as string
    expect((await op(team, p, "automation.update", { automation: id, enabled: false })).t).toBe("result")
  })

  it("the Worker gives SchedulerDO the caller's role from TeamDO, never from the request", async () => {
    const team = newTeam()
    const user = cloudTestUser(199)
    const fakeEnv = {
      TEAM_DO: { idFromName: (n: string) => n, get: () => ({ memberRole: async () => "admin" }) }
    } as unknown as Parameters<typeof principalForOwner>[0]
    const p = await principalForOwner(fakeEnv, "cloud:SchedulerDO", { identity: `user:${user}`, user, team, kind: "session", team_role: "owner" } as Principal)
    expect((p as Principal & { team_role?: string }).team_role).toBe("admin")
    const personal = await principalForOwner(fakeEnv, "cloud:SchedulerDO", { identity: `user:${user}`, user, team: personalTeamIdFor(user), kind: "session" })
    expect((personal as Principal & { team_role?: string }).team_role).toBe("owner")
  })
})

describe("automation audit log", () => {
  it("records who changed what without the body; a member reads only entries of automations they may view", async () => {
    const team = newTeam()
    const alice = member(team, "member")
    const bob = member(team, "member")
    const ada = member(team, "admin")
    const priv = (await create(team, alice, { sharing: "private", name: "private one" })).value.id as string
    const shared = (await create(team, alice, { name: "shared one" })).value.id as string
    expect((await op(team, ada, "automation.update", { automation: shared, name: "renamed" })).t).toBe("result")
    await allowRuns(team)
    expect((await op(team, bob, "automation.run", { automation: shared })).t).toBe("result")
    const all = await read(team, ada, "automation.audit.list")
    expect(all.ok).toBe(true)
    const entries = all.value.entries as Array<{ op: string; actor: string; automation: string; at: number; summary: string }>
    expect(entries.map((e) => [e.op, e.actor, e.automation])).toEqual([
      ["automation.create", alice.user, priv],
      ["automation.create", alice.user, shared],
      ["automation.update", ada.user, shared],
      ["automation.run", bob.user, shared]
    ])
    expect(entries.every((e) => typeof e.at === "number" && typeof e.summary === "string")).toBe(true)
    expect(JSON.stringify(entries)).not.toContain(BODY_TEXT)
    const bobs = (await read(team, bob, "automation.audit.list")).value.entries as Array<{ automation: string }>
    expect(bobs.map((e) => e.automation)).not.toContain(priv)
    expect(bobs.length).toBe(3)
  })
})

/** Every slot of `expr` in (after, until], oldest first. */
const slots = (expr: string, tz: string, after: number, until: number) => {
  const out: Array<number> = []
  for (let t = nextFire(expr, tz, after); t !== null && t <= until; t = nextFire(expr, tz, t)) out.push(t)
  return out
}
const localDay = (ms: number, tz: string) => new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" }).format(ms)

describe("time zones", () => {
  it("a 02:30 daily job in Los Angeles fires once on the spring-forward day", () => {
    const tz = "America/Los_Angeles"
    const fired = slots("30 2 * * *", tz, Date.parse("2026-03-07T00:00:00Z"), Date.parse("2026-03-10T00:00:00Z")).map((t) => localDay(t, tz))
    expect(fired.filter((d) => d === "2026-03-08")).toHaveLength(1)
  })

  it("a 01:30 daily job in Los Angeles fires once, not twice, on the fall-back day", () => {
    const tz = "America/Los_Angeles"
    const fired = slots("30 1 * * *", tz, Date.parse("2026-10-31T00:00:00Z"), Date.parse("2026-11-03T00:00:00Z")).map((t) => localDay(t, tz))
    expect(fired.filter((d) => d === "2026-11-01")).toHaveLength(1)
  })
})

const HOURLY = { type: "cron", expr: "0 * * * *", tz: "UTC" }
/** Imports an hourly automation whose last fired slot is `missed` slots before the newest one. */
const importMissed = async (team: string, p: Principal, catch_up: string, missed: number) => {
  const now = Date.now()
  const newest = slots("0 * * * *", "UTC", now - 2 * HOUR, now).at(-1)!
  const last_slot = newest - missed * HOUR
  const r = await op(team, p, "automation.import", {
    name: `catch-up ${catch_up}`,
    triggers: [HOURLY, { type: "manual" }],
    body: steps,
    catch_up,
    handoff: { id: handoffId(), from: "mac:a908test", source_id: "auto_aaaaaaaaaaaaaaaaaaaa", epoch: 2, last_slot }
  })
  expect(r.t).toBe("result")
  return { id: r.value.id as string, newest, last_slot }
}
const wakeUntilQuiet = async (team: string) => {
  for (let i = 0; i < 14; i++) await inScheduler(team, (s) => s.onWake(Date.now()))
}
const runsOf = async (team: string, p: Principal, automation: string) =>
  ((await read(team, p, "automation.runs.list", { automation, limit: 50 })).value.runs as Array<{ state: string; trigger: { scheduled_at?: number }; error: { code: string } | null }>)

describe("catch-up policy", () => {
  it("latest fires the newest missed slot once", async () => {
    const team = newTeam()
    const p = member(team, "admin")
    const { id, newest } = await importMissed(team, p, "latest", 4)
    await allowRuns(team)
    await wakeUntilQuiet(team)
    const runs = (await runsOf(team, p, id)).filter((r) => r.state !== "skipped")
    expect(runs.map((r) => r.trigger.scheduled_at)).toEqual([newest])
  })

  it("all fires each missed slot once, oldest first", async () => {
    const team = newTeam()
    const p = member(team, "admin")
    const { id, last_slot, newest } = await importMissed(team, p, "all", 4)
    await allowRuns(team)
    await wakeUntilQuiet(team)
    const fired = (await runsOf(team, p, id)).filter((r) => r.state !== "skipped").map((r) => r.trigger.scheduled_at).sort()
    expect(fired).toEqual(slots("0 * * * *", "UTC", last_slot, newest))
  })

  it("all fires at most the newest 10 missed slots and records the rest as missed", async () => {
    const team = newTeam()
    const p = member(team, "admin")
    const { id } = await importMissed(team, p, "all", 15)
    await allowRuns(team)
    await wakeUntilQuiet(team)
    const runs = await runsOf(team, p, id)
    expect(runs.filter((r) => r.state !== "skipped")).toHaveLength(10)
    expect(runs.filter((r) => r.state === "skipped" && r.error?.code === "run.missed").length).toBeGreaterThanOrEqual(1)
  })

  it("none fires nothing late and records one missed run", async () => {
    const team = newTeam()
    const p = member(team, "admin")
    const { id } = await importMissed(team, p, "none", 4)
    await allowRuns(team)
    await wakeUntilQuiet(team)
    const runs = await runsOf(team, p, id)
    expect(runs.filter((r) => r.state !== "skipped")).toEqual([])
    expect(runs.filter((r) => r.error?.code === "run.missed")).toHaveLength(1)
    const a = (await read(team, p, "automation.get", { automation: id })).value
    expect(a.next_run_at).toBeGreaterThan(Date.now())
  })

  it("latest skips a slot older than 24 hours and records it as missed", async () => {
    const team = newTeam()
    const p = member(team, "admin")
    // The object is bound by its first op; the run policy goes in after it.
    await create(team, p)
    await allowRuns(team)
    const yearly = { type: "cron", expr: "0 0 1 1 *", tz: "UTC" }
    const now = Date.now()
    const newest = slots("0 0 1 1 *", "UTC", now - 400 * 24 * HOUR, now).at(-1)!
    if (now - newest < 24 * HOUR) return // the newest slot is within a day (January 1): nothing to show
    const r = await op(team, p, "automation.import", {
      name: "yearly", triggers: [yearly], body: steps, catch_up: "latest",
      handoff: { id: handoffId(), from: "mac:a908test", source_id: "auto_bbbbbbbbbbbbbbbbbbbb", epoch: 2, last_slot: newest - 365 * 24 * HOUR }
    })
    await wakeUntilQuiet(team)
    const runs = await runsOf(team, p, r.value.id)
    expect(runs.map((x) => [x.state, x.error?.code])).toEqual([["skipped", "run.missed"]])
  })
})

describe("teleport handoff (single writer)", () => {
  it("import makes a Cloud-homed copy once per handoff id, with its epoch and last slot", async () => {
    const team = newTeam()
    const p = member(team, "admin")
    const id = handoffId()
    const params = { name: "moved in", triggers: [{ type: "manual" }], body: steps, handoff: { id, from: "mac:a908test", source_id: "auto_cccccccccccccccccccc", epoch: 2, last_slot: 1_700_000_000_000 } }
    const first = await op(team, p, "automation.import", params, `teleport:${id}`)
    expect(first.t).toBe("result")
    expect(first.value).toMatchObject({ home: "cloud", epoch: 2, last_slot: 1_700_000_000_000, sharing: "team", catch_up: "latest" })
    expect(first.value.handoff).toBeUndefined()
    const replay = await op(team, p, "automation.import", params, `teleport:${id}`)
    expect(replay.value.id).toBe(first.value.id)
    // Another key for the same handoff (a client that lost its key) still finds the first copy.
    const again = await op(team, p, "automation.import", params)
    expect(again.value.id).toBe(first.value.id)
    expect((await read(team, p, "automation.list")).value.automations).toHaveLength(1)
  })

  it("begin fences the Cloud copy: no fire, no run, no second handoff; abort lifts the fence", async () => {
    const team = newTeam()
    const p = member(team, "admin")
    const made = await create(team, p, { triggers: [HOURLY, { type: "manual" }] })
    await allowRuns(team)
    const id = made.value.id as string
    const trigger = made.value.triggers[0].id as string
    const next_at = made.value.triggers[0].next_at as number
    const tp = handoffId()
    const begun = await op(team, p, "automation.teleport.begin", { automation: id, handoff: { id: tp, to: "home" } }, `teleport-begin:${tp}`)
    expect(begun.t).toBe("result")
    expect(begun.value.automation.body).toEqual(steps)
    expect(begun.value.epoch).toBe(2)
    expect(begun.value.last_slot).toBeNull()
    await inScheduler(team, async (s) => {
      const fired = answer(s.submitSystem("automation.fire", { automation: id, trigger, scheduled_at: next_at }, `test-fire:${id}`))
      expect(fired.value).toMatchObject({ stale: true })
    })
    expect((await op(team, p, "automation.run", { automation: id })).code).toBe("automation.handoff_pending")
    expect((await op(team, p, "automation.teleport.begin", { automation: id, handoff: { id: handoffId(), to: "cloud" } })).code).toBe("automation.handoff_pending")
    expect((await op(team, p, "automation.teleport.begin", { automation: id, handoff: { id: tp, to: "home" } }, `teleport-begin:${tp}`)).replayed).toBe(true)
    expect((await op(team, p, "automation.teleport.abort", { automation: id, handoff: tp })).t).toBe("result")
    expect((await op(team, p, "automation.run", { automation: id })).t).toBe("result")
  })

  it("complete leaves a tombstone that names the new home; the old id answers automation.moved", async () => {
    const team = newTeam()
    const p = member(team, "admin")
    const id = (await create(team, p)).value.id as string
    const tp = handoffId()
    expect((await op(team, p, "automation.teleport.begin", { automation: id, handoff: { id: tp, to: "ssh:mini-1" } })).t).toBe("result")
    const done = await op(team, p, "automation.teleport.complete", { automation: id, handoff: tp, moved_id: "auto_dddddddddddddddddddd" })
    expect(done.t).toBe("result")
    const list = (await read(team, p, "automation.list")).value
    expect(list.automations.map((a: any) => a.id)).not.toContain(id)
    expect(list.moved).toEqual([expect.objectContaining({ id, moved_to: "ssh:mini-1", moved_id: "auto_dddddddddddddddddddd", epoch: 2 })])
    expect((await read(team, p, "automation.get", { automation: id })).code).toBe("automation.moved")
    // Completing a handoff that is not the pending one changes nothing.
    expect((await op(team, p, "automation.teleport.complete", { automation: id, handoff: handoffId(), moved_id: "auto_eeeeeeeeeeeeeeeeeeee" })).t).toBe("reject")
  })

  it("only someone who may edit the automation moves it", async () => {
    const team = newTeam()
    const alice = member(team, "member")
    const bob = member(team, "member")
    const id = (await create(team, alice)).value.id as string
    expect((await op(team, bob, "automation.teleport.begin", { automation: id, handoff: { id: handoffId(), to: "cloud" } })).code).toBe("auth.forbidden")
  })

  it("the destination grammar is the Chief teleport's, plus cloud", async () => {
    const team = newTeam()
    const p = member(team, "admin")
    const id = (await create(team, p)).value.id as string
    for (const to of ["ssh:-oProxyCommand=x", "elsewhere", "ssh:"]) {
      expect([to, (await op(team, p, "automation.teleport.begin", { automation: id, handoff: { id: handoffId(), to } })).code]).toEqual([to, "validation.invalid"])
    }
  })
})
