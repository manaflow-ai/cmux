import { env, exports } from "cloudflare:workers"
import { runDurableObjectAlarm, runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { idFactory, MemoryRows, type Principal, type ReduceContext } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { schedulerDomain, type SchedulerState } from "../src/domains/scheduler.ts"

/**
 * agents.allowedClasses `run` (enterprise P17-4): runs start inside SchedulerDO, so TeamDO pushes
 * whether the team allows runs to SchedulerDO, and run creation refuses while `run` is absent.
 */
const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; TEAM_DO: DurableObjectNamespace; SCHEDULER_DO: DurableObjectNamespace }
const worker = (exports as unknown as { default: Fetcher }).default
const inDO = runInDurableObject as unknown as (stub: unknown, cb: (instance: any) => Promise<void>) => Promise<void>
const token = async (sub: string) =>
  new SignJWT({ email: `${sub}@example.com`, email_verified: true, name: sub })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))
const call = async (path: string, t: string, body: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${t}` }, body: JSON.stringify(body) })
  return (await res.json()) as any
}
const op = (t: string, name: string, params: unknown) => call("/v1/ops", t, { op: name, params, idempotency_key: crypto.randomUUID(), origin: "user" })
const read = (t: string, name: string, params: unknown = {}) => call("/v1/read", t, { op: name, params })

/** Sets agents.allowedClasses, then runs TeamDO's alarm until it has nothing left to push. */
const setClasses = async (t: string, team: string, classes: ReadonlyArray<string>) => {
  const version = ((await read(t, "team.policy.get")).value?.policy?.version ?? 0) as number
  const r = await op(t, "team.policy.update", { changes: [{ key: "agents.allowedClasses", value: { value: classes, mode: "enforced" } }], expected_version: version, reason: "test" })
  expect(r.ok, JSON.stringify(r)).toBe(true)
  const stub = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team))
  for (let i = 0; i < 5; i++) await runDurableObjectAlarm(stub)
}

describe("run class of agents.allowedClasses (workerd)", { timeout: 60_000 }, () => {
  it("refuses run creation while the team does not allow runs, and allows it again", async () => {
    const t = await token("run-policy-1")
    const team = (await op(t, "user.ensure", {})).value.personal_team as string
    const created = await op(t, "automation.create", { name: "nightly", triggers: [{ type: "manual" }], body: { type: "steps", steps: [{ type: "note", text: "hi" }] } })
    expect(created.ok, JSON.stringify(created)).toBe(true)
    const automation = created.value.id as string

    await setClasses(t, team, ["mux", "agent"])
    const refused = await op(t, "automation.run", { automation })
    expect(refused).toMatchObject({ ok: false, error: { code: "policy.denied" } })

    await setClasses(t, team, ["mux", "agent", "run"])
    const allowed = await op(t, "automation.run", { automation })
    expect(allowed.ok, JSON.stringify(allowed)).toBe(true)
  })

  it("a deny cancels queued runs that have no Workflow yet; started runs keep running (pure)", () => {
    const user: Principal = { identity: "session:user_aaaaaaaaaaaaaaaaaaaa", kind: "session", user: "user_aaaaaaaaaaaaaaaaaaaa", team: "team_aaaaaaaaaaaaaaaaaaaa" }
    const system: Principal = { identity: "system:team", kind: "system" }
    let n = 0
    const ctx = (principal: Principal): ReduceContext => ({ principal, now: 1_800_000_000_000, tx: `tx${n}`, newId: idFactory(`tx${n++}`), rows: new MemoryRows() })
    let s: SchedulerState = schedulerDomain.initial()
    const created = schedulerDomain.reduce(s, "automation.create", { name: "x", triggers: [{ type: "manual" }], body: { type: "steps", steps: [{ type: "note", text: "n" }] }, concurrency: { max: 10, on_limit: "queue" } }, ctx(user))
    if (!created.ok) throw new Error(created.code)
    s = created.state
    const automation = Object.keys(s.automations)[0]!
    const ids: Array<string> = []
    for (let i = 0; i < 2; i++) {
      const r = schedulerDomain.reduce(s, "automation.run", { automation }, ctx(user))
      if (!r.ok) throw new Error(r.code)
      s = r.state
      ids.push((r.value as { id: string }).id)
    }
    const started = schedulerDomain.reduce(s, "run.dispatched", { run: ids[0] }, ctx(system))
    if (!started.ok) throw new Error(started.code)
    s = started.state
    const denied = schedulerDomain.reduce(s, "scheduler.run_policy", { version: 3, runs_allowed: false }, ctx(system))
    if (!denied.ok) throw new Error(denied.code)
    expect(denied.state.runs[ids[0]!]).toMatchObject({ state: "queued", dispatched: true })
    expect(denied.state.runs[ids[1]!]).toMatchObject({ state: "cancelled", error: { code: "automation.stopped" } })
    expect(denied.outbox).toHaveLength(1)
    // An older or repeated push changes nothing.
    expect(schedulerDomain.reduce(denied.state, "scheduler.run_policy", { version: 2, runs_allowed: true }, ctx(system))).toMatchObject({ ok: true, changed: false })
    expect(schedulerDomain.reduce(denied.state, "automation.run", { automation }, ctx(user))).toMatchObject({ ok: false, code: "policy.denied" })
  })

  it("a cron fire while runs are not allowed advances the schedule and starts no run", async () => {
    const t = await token("run-policy-2")
    const team = (await op(t, "user.ensure", {})).value.personal_team as string
    const created = await op(t, "automation.create", { name: "cron", triggers: [{ type: "cron", expr: "* * * * *", tz: "UTC" }], body: { type: "steps", steps: [{ type: "note", text: "hi" }] } })
    expect(created.ok, JSON.stringify(created)).toBe(true)
    const automation = created.value.id as string
    await setClasses(t, team, ["mux"])
    const before = (await read(t, "automation.get", { automation })).value.triggers[0].next_at as number
    const scheduler = testEnv.SCHEDULER_DO.get(testEnv.SCHEDULER_DO.idFromName(team))
    let value: any
    await inDO(scheduler, async (s) => {
      const trigger = s.boundEngine.currentState.automations[automation].triggers[0].id
      const r = s.submitSystem("automation.fire", { automation, trigger, scheduled_at: before }, `fire-test:${before}`)
      value = r.frames.find((f: { t: string }) => f.t === "result" || f.t === "reject")
    })
    expect(value).toMatchObject({ t: "result", value: { skipped: "policy.denied" } })
    const after = (await read(t, "automation.get", { automation })).value
    expect(after.triggers[0].next_at).toBeGreaterThan(before)
    const runs = (await read(t, "automation.runs.list", { automation })).value.runs
    expect(runs).toHaveLength(0)
  })
})
