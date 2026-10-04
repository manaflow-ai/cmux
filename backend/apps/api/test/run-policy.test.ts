import { env, exports } from "cloudflare:workers"
import { runDurableObjectAlarm, runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { idFactory, MemoryRows, type Principal, type ReduceContext } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { schedulerDomain, TERMINAL, type SchedulerState } from "../src/domains/scheduler.ts"
import { afterCreate } from "../src/domains/scheduler-policy.ts"

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


const hmac = async (secret: string, msg: string) => {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"])
  return [...new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(msg)))].map((b) => b.toString(16).padStart(2, "0")).join("")
}
const postHook = async (path: string, secret: string, body: string) => {
  const ts = String(Math.floor(Date.now() / 1000))
  const res = await worker.fetch(`https://api.test${path}`, { method: "POST", headers: { "content-type": "application/json", "x-cmux-timestamp": ts, "x-cmux-signature": `v1=${await hmac(secret, `${ts}.${body}`)}` }, body })
  return { status: res.status, json: (await res.json()) as any }
}
const steps = { type: "steps", steps: [{ type: "note", text: "hi" }] }

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
    let s: SchedulerState = ({ ...schedulerDomain.initial(), run_policy: { version: 0, runs_allowed: true } })
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

  it("a webhook answers 403 policy.denied, a provider event starts no run", async () => {
    const t = await token("run-policy-4")
    const team = (await op(t, "user.ensure", {})).value.personal_team as string
    const hook = await op(t, "automation.create", { name: "hook", triggers: [{ type: "webhook" }], body: steps })
    const trigger = hook.value.triggers[0].id as string
    const connection = "conn_aaaaaaaaaaaaaaaaaaaa"
    const ev = await op(t, "automation.create", { name: "ev", triggers: [{ type: "event", source: "integration", connection, event: "issue.opened" }], body: steps })
    expect(ev.ok, JSON.stringify(ev)).toBe(true)
    await setClasses(t, team, ["mux"])
    const { path, secret } = (await read(t, "automation.webhook.get", { automation: hook.value.id, trigger })).value
    const r = await postHook(path, secret, JSON.stringify({ a: 1 }))
    expect(r).toMatchObject({ status: 403, json: { ok: false, code: "policy.denied" } })
    await inDO(testEnv.SCHEDULER_DO.get(testEnv.SCHEDULER_DO.idFromName(team)), async (s) => {
      const out = await s.deliverEvent(team, { connection, sharing: "team", created_by: "x", provider: "github", event: "issue.opened", delivery_id: "d1", payload: {} })
      expect(out.runs).toBe(0)
      expect(Number(s.ctx.storage.sql.exec("SELECT COUNT(*) AS n FROM deferred_deliveries").toArray()[0].n)).toBe(0)
    })
    expect((await read(t, "automation.runs.list", { automation: ev.value.id })).value.runs).toHaveLength(0)
  })

  it("fails closed: a scheduler without the policy pulls it from TeamDO, and refuses runs while TeamDO is unreachable", async () => {
    const t = await token("run-policy-5")
    const team = (await op(t, "user.ensure", {})).value.personal_team as string
    const a = await op(t, "automation.create", { name: "m", triggers: [{ type: "manual" }], body: steps })
    const stub = testEnv.SCHEDULER_DO.get(testEnv.SCHEDULER_DO.idFromName(team))
    await inDO(stub, async (s) => {
      expect(s.boundEngine.currentState.run_policy).toBeUndefined()
      const realEnv = s.env
      s.env = { ...realEnv, TEAM_DO: { idFromName: () => "x", get: () => ({ runPolicy: async () => { throw new Error("down") } }) } }
      const principal = { identity: "session:x", kind: "session", user: "user_cccccccccccccccccccc", team }
      const r = await s.submit(team, principal, { t: "op", op: "automation.run", params: { automation: a.value.id }, idempotency_key: "k-down", origin: "cli" })
      expect(r.frames.find((f: { t: string }) => f.t === "reject")).toMatchObject({ code: "policy.pending" })
      s.env = realEnv
      const ok = await s.submit(team, principal, { t: "op", op: "automation.run", params: { automation: a.value.id }, idempotency_key: "k-up", origin: "cli" })
      expect(ok.frames.find((f: { t: string }) => f.t === "result"), JSON.stringify(ok.frames)).toBeDefined()
      expect(s.boundEngine.currentState.run_policy).toMatchObject({ runs_allowed: true })
    })
  })

  it("TeamDO backs off after a failed push and pushes after the backoff", async () => {
    const t = await token("run-policy-6")
    const team = (await op(t, "user.ensure", {})).value.personal_team as string
    const version = ((await read(t, "team.policy.get")).value?.policy?.version ?? 0) as number
    expect((await op(t, "team.policy.update", { changes: [{ key: "agents.allowedClasses", value: { value: ["mux"], mode: "enforced" } }], expected_version: version, reason: "test" })).ok).toBe(true)
    await inDO(testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team)), async (d) => {
      const realEnv = d.env
      d.env = { ...realEnv, SCHEDULER_DO: { idFromName: () => "x", get: () => ({ applyRunPolicy: async () => { throw new Error("down") } }) } }
      const now = Date.now()
      await d.onWake(now)
      expect(d.runSyncRetryAt).toBeGreaterThan(now)
      expect(d.boundEngine.currentState.runs_synced).toBeUndefined()
      expect(d.nextWakeAt(d.boundEngine.currentState, now)).toBe(d.runSyncRetryAt)
      d.env = realEnv
      await d.onWake(d.runSyncRetryAt)
      expect(d.boundEngine.currentState.runs_synced).toMatchObject({ runs_allowed: false })
    })
  })

  it("the sync ops are internal: a session cannot call them", async () => {
    const t = await token("run-policy-7")
    await op(t, "user.ensure", {})
    for (const name of ["scheduler.run_policy", "team.policy.runs_synced"]) {
      const r = await op(t, name, { version: 99, runs_allowed: true })
      expect(r.ok === true, JSON.stringify(r)).toBe(false)
      expect(r.code ?? r.error?.code).toBe("validation.invalid")
    }
  })

  it("a continue trigger while runs are denied ends its chain without a run", async () => {
    const t = await token("run-policy-8")
    const team = (await op(t, "user.ensure", {})).value.personal_team as string
    const created = await op(t, "automation.create", { name: "loop", triggers: [{ type: "manual" }, { type: "continue", until: ["goal_met"], cooldown_seconds: 60, max_runs: 3 }], body: steps })
    const automation = created.value.id as string
    await setClasses(t, team, ["mux"])
    await inDO(testEnv.SCHEDULER_DO.get(testEnv.SCHEDULER_DO.idFromName(team)), async (s) => {
      const a = s.boundEngine.currentState.automations[automation]
      const cont = a.triggers.find((x: { spec: { type: string } }) => x.spec.type === "continue")
      // Put the continue trigger in its due state as a finished run would (pure reducer path).
      const at = Date.now()
      s.boundEngine.currentState.automations[automation] = { ...a, triggers: a.triggers.map((x: { id: string }) => (x.id === cont.id ? { ...x, next_at: at } : x)) }
      const r = s.submitSystem("automation.fire", { automation, trigger: cont.id, scheduled_at: at }, `fire-cont:${at}`)
      expect(r.frames.find((f: { t: string }) => f.t === "result")).toMatchObject({ value: { skipped: "policy.denied" } })
      expect(s.boundEngine.currentState.automations[automation].triggers.find((x: { id: string }) => x.id === cont.id).next_at).toBeNull()
    })
    expect((await read(t, "automation.runs.list", { automation })).value.runs).toHaveLength(0)
  })

  it("a cancelled run's Workflow is told to stop on its next report", async () => {
    const t = await token("run-policy-9")
    const team = (await op(t, "user.ensure", {})).value.personal_team as string
    const hook = await op(t, "automation.create", { name: "w", triggers: [{ type: "webhook" }], body: steps })
    await inDO(testEnv.SCHEDULER_DO.get(testEnv.SCHEDULER_DO.idFromName(team)), async (s) => {
      await s.ensureRunPolicy(team)
      // One synchronous turn: a queued run, then a deny that cancels it before any dispatch.
      const r = s.submitSystem("automation.deliver", { automation: hook.value.id, trigger: hook.value.triggers[0].id, delivery_id: "d-stop" }, "deliver-stop")
      const run = r.frames.find((f: { t: string }) => f.t === "result").value.id as string
      s.submitSystem("scheduler.run_policy", { version: 99, runs_allowed: false }, "run-policy:99:0")
      expect(s.boundEngine.currentState.runs[run].state).toBe("cancelled")
      expect(await s.reportRun(team, { run, state: "running", step: -1 })).toMatchObject({ ok: true, stopped: true })
      expect(s.boundEngine.currentState.runs[run].state).toBe("cancelled")
    })
  })

  it("terminate-after-create: a run that became terminal while its Workflow was created is terminated (pure)", () => {
    const run = (state: string) => ({ runs: { run_x: { state } } }) as unknown as Pick<SchedulerState, "runs">
    expect(afterCreate(run("queued"), "run_x")).toBe("dispatched")
    expect(afterCreate(run("running"), "run_x")).toBe("dispatched")
    for (const s of TERMINAL) expect(afterCreate(run(s), "run_x")).toBe("terminate")
    expect(afterCreate({ runs: {} }, "run_x")).toBe("terminate")
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

  it("a cron fire refused as policy.pending retries in a second, without backoff (review P2)", async () => {
    const t = await token("run-policy-pending")
    const team = (await op(t, "user.ensure", {})).value.personal_team as string
    const created = await op(t, "automation.create", { name: "cron", triggers: [{ type: "cron", expr: "* * * * *", tz: "UTC" }], body: steps })
    expect(created.ok, JSON.stringify(created)).toBe(true)
    const automation = created.value.id as string
    const stub = testEnv.SCHEDULER_DO.get(testEnv.SCHEDULER_DO.idFromName(team))
    await inDO(stub, async (s) => {
      expect(s.boundEngine.currentState.run_policy).toBeUndefined()
      const realEnv = s.env
      // TeamDO is unreachable, so the policy stays unloaded and the fire is refused as policy.pending.
      s.env = { ...realEnv, TEAM_DO: { idFromName: () => "x", get: () => ({ runPolicy: async () => { throw new Error("down") } }) } }
      const at = s.boundEngine.currentState.automations[automation].triggers[0].next_at as number
      await s.onWake(at + 1)
      const rows = s.ctx.storage.sql.exec("SELECT key, attempts, at FROM retry_state WHERE key LIKE 'fire:%'").toArray()
      expect(rows).toHaveLength(1)
      expect(rows[0]).toMatchObject({ attempts: 0, at: at + 1 + 1000 })
      s.env = realEnv
    })
  })
})
