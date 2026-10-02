import { env, exports } from "cloudflare:workers"
import { introspectWorkflowInstance, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"

const testEnv = env as unknown as {
  STACK_PROJECT_ID: string
  STACK_TEST_PRIVATE_JWK: string
  SCHEDULER_DO: DurableObjectNamespace
  AUTOMATION_RUN: Workflow
}
const worker = (exports as unknown as { default: Fetcher }).default

const sessionToken = async (stackUser: string) => {
  const key = await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256")
  return new SignJWT({ email: `${stackUser}@example.com`, name: stackUser })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(stackUser)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(key)
}

const call = async (path: string, token: string, body: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify(body)
  })
  return { status: res.status, json: (await res.json()) as any }
}
const op = (token: string, name: string, params: unknown, key: string = crypto.randomUUID()) => call("/v1/ops", token, { op: name, params, idempotency_key: key, origin: "cli" })
const read = (token: string, name: string, params: unknown = {}) => call("/v1/read", token, { op: name, params })

const signedIn = async (stackUser: string) => {
  const token = await sessionToken(stackUser)
  const ensure = await op(token, "user.ensure", {})
  expect(ensure.json.ok).toBe(true)
  return { token, team: ensure.json.value.personal_team as string }
}

/** Test access to the DO's protected wake/submit paths. */
interface SchedulerInternals {
  submitSystem(op: string, params: unknown, key: string): { frames: Array<{ t: string; replayed?: boolean }> }
  onWake(now: number): Promise<void>
}
const scheduler = (team: string) => testEnv.SCHEDULER_DO.get(testEnv.SCHEDULER_DO.idFromName(team))
const inScheduler = (team: string, fn: (s: SchedulerInternals) => Promise<void>) =>
  (runInDurableObject as unknown as (stub: unknown, cb: (instance: unknown) => Promise<void>) => Promise<void>)(scheduler(team), (instance) => fn(instance as SchedulerInternals))

describe("automations end to end (workerd)", () => {
  it("creates, lists, runs manually through a Workflow, and records the run", async () => {
    const { token, team } = await signedIn("auto-user-1")
    const create = await op(token, "automation.create", {
      name: "nightly digest",
      triggers: [{ type: "manual" }, { type: "cron", expr: "0 3 * * *", tz: "America/Los_Angeles" }],
      body: { type: "steps", steps: [{ type: "note", text: "start" }, { type: "sleep", seconds: 30 }, { type: "note", text: "end" }] }
    }, "create-1")
    expect(create.json.ok).toBe(true)
    expect(create.json.stream).toBe(`scheduler:${team}`)
    const automation = create.json.value.id as string
    expect(create.json.value.next_run_at).toBeGreaterThan(Date.now())
    // Idempotency: the same key replays with the same automation.
    const replay = await op(token, "automation.create", {
      name: "nightly digest",
      triggers: [{ type: "manual" }, { type: "cron", expr: "0 3 * * *", tz: "America/Los_Angeles" }],
      body: { type: "steps", steps: [{ type: "note", text: "start" }, { type: "sleep", seconds: 30 }, { type: "note", text: "end" }] }
    }, "create-1")
    expect(replay.json).toMatchObject({ ok: true, replayed: true, value: { id: automation } })

    const list = await read(token, "automation.list")
    expect(list.json.value.automations.map((a: any) => a.id)).toEqual([automation])

    const run = await op(token, "automation.run", { automation })
    expect(run.json.value.state).toBe("queued")
    const runId = run.json.value.id as string

    const instance = await introspectWorkflowInstance(testEnv.AUTOMATION_RUN, runId)
    try {
      await instance.modify(async (m) => {
        await m.disableSleeps()
      })
      // The commit set the alarm; run it now: it dispatches the queued run as Workflow instance `runId`.
      await runDurableObjectAlarm(scheduler(team))
      await instance.waitForStatus("complete")
    } finally {
      await instance[Symbol.asyncDispose]()
    }
    const runs = await read(token, "automation.runs.list", { automation })
    expect(runs.json.value.runs).toHaveLength(1)
    expect(runs.json.value.runs[0]).toMatchObject({ id: runId, state: "succeeded", step: 2, error: null })
    expect(runs.json.value.runs[0].started_at).toBeGreaterThan(0)
    expect(runs.json.value.runs[0].finished_at).toBeGreaterThanOrEqual(runs.json.value.runs[0].started_at)
    expect(runs.json.value.runs[0].dispatched).toBeUndefined()

    // Public HTTP cannot call internal ops.
    const fire = await op(token, "automation.fire", { automation, trigger: create.json.value.triggers[1].id, scheduled_at: 0 })
    expect(fire.status).toBe(400)
  })

  it("two alarms for the same cron slot start exactly one run", async () => {
    const { token, team } = await signedIn("auto-user-2")
    const create = await op(token, "automation.create", {
      name: "every minute",
      triggers: [{ type: "cron", expr: "* * * * *", tz: "UTC" }],
      body: { type: "steps", steps: [{ type: "note", text: "tick" }] }
    })
    const automation = create.json.value.id as string
    const slot = create.json.value.next_run_at as number
    await inScheduler(team, async (instance) => {
      // Both wakes see the same due slot (as a retried or duplicated alarm would).
      const fires = [1, 2].map(() =>
        instance.submitSystem("automation.fire", { automation, trigger: create.json.value.triggers[0].id, scheduled_at: slot }, `fire:${automation}:${create.json.value.triggers[0].id}:${slot}`)
      )
      const replayed = fires.map((f) => f.frames.find((x) => x.t === "result")?.replayed)
      expect(replayed).toEqual([false, true])
      await instance.onWake(slot + 1)
    })
    const runs = await read(token, "automation.runs.list", { automation })
    expect(runs.json.value.runs).toHaveLength(1)
    expect(runs.json.value.runs[0].trigger).toMatchObject({ type: "cron", scheduled_at: slot })
  })

  it("a due slot fires from the alarm once even when the alarm runs twice", async () => {
    const { token, team } = await signedIn("auto-user-3")
    const create = await op(token, "automation.create", {
      name: "every minute",
      triggers: [{ type: "cron", expr: "* * * * *", tz: "UTC" }],
      body: { type: "steps", steps: [{ type: "note", text: "tick" }] }
    })
    const automation = create.json.value.id as string
    const slot = create.json.value.next_run_at as number
    await inScheduler(team, async (instance) => {
      await instance.onWake(slot + 1)
      await instance.onWake(slot + 2)
    })
    const runs = await read(token, "automation.runs.list", { automation })
    expect(runs.json.value.runs).toHaveLength(1)
    const listed = await read(token, "automation.get", { automation })
    expect(listed.json.value.next_run_at).toBeGreaterThan(slot)
  })

  it("isolates teams: another user cannot see or run this team's automations", async () => {
    const a = await signedIn("auto-user-a")
    const b = await signedIn("auto-user-b")
    const create = await op(a.token, "automation.create", { name: "mine", triggers: [{ type: "manual" }], body: { type: "steps", steps: [{ type: "note", text: "x" }] } })
    const automation = create.json.value.id as string
    expect((await read(b.token, "automation.list")).json.value.automations).toEqual([])
    const run = await op(b.token, "automation.run", { automation })
    expect(run.json).toMatchObject({ ok: false, error: { code: "selector.not_found" } })
  })
})
