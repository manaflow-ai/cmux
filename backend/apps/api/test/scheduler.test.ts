import { env, exports } from "cloudflare:workers"
import { evictDurableObject, introspectWorkflowInstance, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test"
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
/** runInDurableObject with an untyped stub (its generic inference recurses too deep on our DO types). */
const inDO = runInDurableObject as unknown as (stub: unknown, cb: (instance: any, state: DurableObjectState) => Promise<void>) => Promise<void>
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

  it("a far cron alarm never delays the outbox drain", async () => {
    const { token, team } = await signedIn("auto-user-4")
    await op(token, "automation.create", { name: "yearly", triggers: [{ type: "cron", expr: "0 0 1 1 *", tz: "UTC" }], body: { type: "steps", steps: [{ type: "note", text: "x" }] } })
    // The create committed an outbox row: its drain must run now, not at the yearly cron alarm.
    // With no database in tests the drain fails and records an attempt; wait for that (bounded).
    const deadline = Date.now() + 10_000
    let attempts = 0
    while (attempts === 0 && Date.now() < deadline) {
      await inDO(scheduler(team), async (_i, state) => {
        attempts = state.storage.sql.exec("SELECT attempts FROM do_entity").toArray()[0]!.attempts as number
      })
      if (attempts === 0) await new Promise((r) => setTimeout(r, 50))
    }
    expect(attempts).toBeGreaterThan(0)
    await inDO(scheduler(team), async (_i, state) => {
      const alarm = await state.storage.getAlarm()
      // The backoff retry is minutes away; the yearly cron slot is not what the alarm waits for.
      expect(alarm === null || alarm < Date.now() + 10 * 60_000).toBe(true)
    })
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

const hmac = async (secret: string, msg: string) => {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"])
  return [...new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(msg)))].map((b) => b.toString(16).padStart(2, "0")).join("")
}

const postHook = async (path: string, secret: string, body: string, opts: { ts?: number; delivery?: string; sig?: string } = {}) => {
  const ts = String(opts.ts ?? Math.floor(Date.now() / 1000))
  const headers: Record<string, string> = { "content-type": "application/json", "x-cmux-timestamp": ts, "x-cmux-signature": opts.sig ?? `v1=${await hmac(secret, `${ts}.${body}`)}` }
  if (opts.delivery) headers["x-cmux-delivery"] = opts.delivery
  const res = await worker.fetch(`https://api.test${path}`, { method: "POST", headers, body })
  return { status: res.status, json: (await res.json()) as any }
}

describe("webhook triggers (workerd)", () => {
  it("verifies, dedupes and turns a signed delivery into one run with its input", async () => {
    const { token, team } = await signedIn("hook-user-1")
    const create = await op(token, "automation.create", {
      name: "on deploy",
      triggers: [{ type: "webhook" }],
      body: { type: "steps", steps: [{ type: "note", text: "deployed" }] }
    })
    expect(create.json.value.triggers[0].status).toBe("active")
    const automation = create.json.value.id as string
    const trigger = create.json.value.triggers[0].id as string
    const hook = await read(token, "automation.webhook.get", { automation, trigger })
    expect(hook.status).toBe(200)
    const { path, secret } = hook.json.value as { path: string; secret: string }
    expect(path).toBe(`/v1/hooks/automation/${team}/${trigger}`)
    expect(secret).toMatch(/^whsec_[0-9a-f]{64}$/)
    // Another team cannot read this trigger's secret.
    const other = await signedIn("hook-user-2")
    expect((await read(other.token, "automation.webhook.get", { automation, trigger })).status).toBe(400)

    const body = JSON.stringify({ service: "web", sha: "abc123" })
    expect((await postHook(path, secret, body, { sig: "v1=" + "0".repeat(64) })).status).toBe(401)
    expect((await postHook(path, secret, body, { ts: Math.floor(Date.now() / 1000) - 3600 })).status).toBe(401)
    expect((await postHook(path, `${secret}x`, body)).status).toBe(401)
    const big = JSON.stringify({ blob: "x".repeat(300 * 1024) })
    expect((await postHook(path, secret, big)).status).toBe(413)

    const ts = Math.floor(Date.now() / 1000)
    const first = await postHook(path, secret, body, { delivery: "deploy-1", ts })
    expect(first.status).toBe(202)
    expect(first.json).toMatchObject({ ok: true, status: "accepted", label: "deploy-1" })
    expect(first.json.delivery).toMatch(/^sha256:[0-9a-f]{40}$/)
    const again = await postHook(path, secret, body, { delivery: "deploy-1", ts })
    expect(again.json).toMatchObject({ status: "duplicate", run: first.json.run })
    // A captured request replayed with a new (unsigned) delivery header is still the same delivery.
    const replay = await postHook(path, secret, body, { delivery: "deploy-2", ts })
    expect(replay.json).toMatchObject({ status: "duplicate", run: first.json.run })

    const runId = first.json.run as string
    // The input waits outside entity state until dispatch (checked in one DO turn, before any alarm can run).
    await inDO(scheduler(team), async (instance, state) => {
      const r = await instance.deliverWebhook(team, trigger, "direct-1", { body: { probe: true } })
      expect(r.status).toBe("accepted")
      const rows = state.storage.sql.exec("SELECT json FROM run_inputs WHERE run = ?", r.run).toArray()
      expect(JSON.parse(rows[0]!.json as string)).toEqual({ body: { probe: true } })
      expect(JSON.stringify(state.storage.sql.exec("SELECT json FROM own_state").toArray())).not.toContain("probe")
    })
    const instance = await introspectWorkflowInstance(testEnv.AUTOMATION_RUN, runId)
    try {
      await runDurableObjectAlarm(scheduler(team))
      await instance.waitForStatus("complete")
    } finally {
      await instance[Symbol.asyncDispose]()
    }
    await runDurableObjectAlarm(scheduler(team))
    const runs = await read(token, "automation.runs.list", { automation })
    expect(runs.json.value.runs).toHaveLength(2)
    expect(runs.json.value.runs.find((r: any) => r.id === runId)).toMatchObject({ state: "succeeded", trigger: { type: "webhook", delivery_id: first.json.delivery } })
    await inDO(scheduler(team), async (_i, state) => {
      expect(state.storage.sql.exec("SELECT run FROM run_inputs").toArray()).toHaveLength(0)
    })
  })

  it("at its deadline a run whose Workflow is gone becomes dead, freeing the slot (no periodic check)", async () => {
    const { token, team } = await signedIn("hook-user-4")
    const create = await op(token, "automation.create", { name: "w", triggers: [{ type: "webhook" }], body: { type: "steps", steps: [{ type: "note", text: "x" }] } })
    const automation = create.json.value.id as string
    const trigger = create.json.value.triggers[0].id as string
    let run = ""
    await inDO(scheduler(team), async (instance, state) => {
      // One synchronous turn: a delivered run marked dispatched with no Workflow instance behind it.
      const r = instance.submitSystem("automation.deliver", { automation, trigger, delivery_id: "orphan" }, "deliver-orphan")
      run = r.frames.find((f: any) => f.t === "result").value.id
      instance.submitSystem("run.dispatched", { run }, `dispatch:${run}`)
      const rec = JSON.parse(state.storage.sql.exec("SELECT json FROM own_state").toArray()[0]!.json as string).runs[run]
      // Note-only body: deadline = dispatch + one hour of grace; the alarm targets exactly that instant.
      expect(rec.deadline_at - Date.now()).toBeGreaterThan(59 * 60_000)
      expect(instance.nextWakeAt(instance.boundEngine.currentState, Date.now())).toBeLessThanOrEqual(rec.deadline_at)
      await instance.enforceDeadlines(Date.now() + 30 * 60_000)
      expect(instance.boundEngine.currentState.runs[run].state).toBe("queued")
      await instance.enforceDeadlines(rec.deadline_at + 1)
    })
    const runs = await read(token, "automation.runs.list", { automation })
    expect(runs.json.value.runs.find((r: any) => r.id === run)).toMatchObject({ state: "dead", error: { code: "run.dead" } })
  })

  it("a Workflow still running at its deadline is terminated and the run fails", async () => {
    const { token, team } = await signedIn("hook-user-6")
    const create = await op(token, "automation.create", {
      name: "slow",
      triggers: [{ type: "manual" }],
      body: { type: "steps", steps: [{ type: "sleep", seconds: 3600 }] },
      budget: { wall_clock_seconds: 60 }
    })
    const automation = create.json.value.id as string
    const run = (await op(token, "automation.run", { automation })).json.value.id as string
    const wf = await introspectWorkflowInstance(testEnv.AUTOMATION_RUN, run)
    try {
      await runDurableObjectAlarm(scheduler(team))
      await wf.waitForStepResult({ name: "sleeping-0" })
      await inDO(scheduler(team), async (instance) => {
        const rec = instance.boundEngine.currentState.runs[run]
        expect(rec.deadline_at - Date.now()).toBeLessThanOrEqual(60_000)
        await instance.enforceDeadlines(rec.deadline_at + 1)
      })
      await wf.waitForStatus("terminated")
    } finally {
      await wf[Symbol.asyncDispose]()
    }
    const runs = await read(token, "automation.runs.list", { automation })
    expect(runs.json.value.runs[0]).toMatchObject({ id: run, state: "failed", error: { code: "budget.wall_clock" } })
  })

  it("retry backoff survives a restart of the object", async () => {
    const { token, team } = await signedIn("hook-user-7")
    await op(token, "automation.list", {})
    await op(token, "automation.create", { name: "r", triggers: [{ type: "manual" }], body: { type: "steps", steps: [{ type: "note", text: "x" }] } })
    let at = 0
    await inDO(scheduler(team), async (instance) => {
      instance.failed("dispatch:run_00000000000000000000", Date.now(), "test")
      at = instance.retryAt("dispatch:run_00000000000000000000")
      expect(at).toBeGreaterThan(Date.now())
    })
    await evictDurableObject(scheduler(team) as never)
    await inDO(scheduler(team), async (instance) => {
      expect(instance.retryAt("dispatch:run_00000000000000000000")).toBe(at)
    })
  })

  it("webhook dedupe outlives the request ledger's replay window", async () => {
    const { token, team } = await signedIn("hook-user-8")
    const create = await op(token, "automation.create", { name: "d", triggers: [{ type: "webhook" }], body: { type: "steps", steps: [{ type: "note", text: "x" }] } })
    const trigger = create.json.value.triggers[0].id as string
    await inDO(scheduler(team), async (instance) => {
      const first = await instance.deliverWebhook(team, trigger, "sha256:abc", { body: 1 })
      expect(first.status).toBe("accepted")
      // Forget every ledger key, as the 7-day prune would.
      instance.boundEngine.pruneLedger(Number.MAX_SAFE_INTEGER, 100000)
      const again = await instance.deliverWebhook(team, trigger, "sha256:abc", { body: 1 })
      expect(again).toEqual({ status: "duplicate", run: first.run })
    })
  })

  it("webhook secrets are for human sessions only", async () => {
    const { token } = await signedIn("hook-user-5")
    const create = await op(token, "automation.create", { name: "s", triggers: [{ type: "webhook" }], body: { type: "steps", steps: [{ type: "note", text: "x" }] } })
    const user = (await op(token, "user.ensure", {})).json.value.id as string
    const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
    const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
    const reg = await op(token, "install.register", { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y }, kind: "cli", name: "cli", device_name: "d", platform: "macos" })
    const install = reg.json.value.id as string
    const ch = (await (await worker.fetch("https://api.test/v1/auth/challenge", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ user, install }) })).json()) as any
    const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${ch.message_prefix}${ch.nonce}`)))
    const b64u = btoa(String.fromCharCode(...sig)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
    const tok = (await (await worker.fetch("https://api.test/v1/auth/token", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ user, install, nonce: ch.nonce, signature: b64u }) })).json()) as any
    const r = await read(tok.access_token, "automation.webhook.get", { automation: create.json.value.id, trigger: create.json.value.triggers[0].id })
    expect(r.status).toBe(403)
    expect((await read(tok.access_token, "automation.list")).status).toBe(200)
  })

  it("answers 404 for an unknown trigger and 409 for a disabled automation", async () => {
    const { token, team } = await signedIn("hook-user-3")
    const create = await op(token, "automation.create", { name: "x", triggers: [{ type: "webhook" }], body: { type: "steps", steps: [{ type: "note", text: "x" }] } })
    const automation = create.json.value.id as string
    const trigger = create.json.value.triggers[0].id as string
    const { path, secret } = (await read(token, "automation.webhook.get", { automation, trigger })).json.value
    await op(token, "automation.update", { automation, enabled: false })
    expect((await postHook(path, secret, "{}")).status).toBe(409)
    expect((await worker.fetch(`https://api.test/v1/hooks/automation/${team}/not-an-id`, { method: "POST", body: "{}" })).status).toBe(404)
    expect((await worker.fetch(`https://api.test/v1/hooks/automation/team_00000000000000000000/trg_00000000000000000000`, { method: "POST", body: "{}" })).status).toBe(401)
  })
})
