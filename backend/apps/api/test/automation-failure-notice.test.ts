import { describe, expect, it } from "vitest"
import { failureNotice } from "../src/domains/scheduler-notice.ts"
import { schedulerPoster } from "../src/domains/feed.ts"

/** Spec section 12 (models-scout): a failed Cloud run notifies its creator. Exit 3 = a failed check, 1 = a crash. */

const run = (over: Record<string, unknown>) => ({ id: "run_bbbbbbbbbbbbbbbbbbbb", automation: "auto_cccccccccccccccccccc", owner: "team_1", state: "failed", error: null, ...over }) as never

describe("failureNotice", () => {
  it("a failed check (exit 3) posts a high notice to the creator's Feed, keyed once per run", () => {
    const n = failureNotice(run({ error: { code: "machine.exit", message: "step 2: exit 3: 2 of 40 models failed" } }), { name: "models-scout", created_by: "user_1" })!
    expect(n.target).toEqual({ class: "FeedDO", name: "user_1" })
    expect(n.kind).toBe("feed.post")
    expect(n.entity).toBe("automation-failed:run_bbbbbbbbbbbbbbbbbbbb")
    const p = n.payload as Record<string, any>
    expect(p).toMatchObject({ type: "notice", kind: "notice", priority: "high", dedupe_key: "automation-failed:auto_cccccccccccccccccccc", thread: "automation:auto_cccccccccccccccccccc" })
    expect(p.title).toBe("models-scout: a check failed")
    expect(p.body).toContain("2 of 40 models failed")
    expect(p.poster).toEqual({ label: "Automations" })
  })

  it("exit 1 is a crash; a timeout and a dead run say so", () => {
    const t = (error: unknown, state = "failed") => (failureNotice(run({ error, state }), { name: "scout", created_by: "u" })!.payload as { title: string }).title
    expect(t({ code: "machine.exit", message: "step 1: exit 1: Traceback" })).toBe("scout: crashed")
    expect(t({ code: "machine.timeout", message: "step 3: timed out after 290 s" })).toBe("scout: timed out")
    expect(t({ code: "run.dead", message: "no final report" }, "dead")).toBe("scout: stopped without a result")
    expect(t({ code: "machine.not_found", message: "gone" })).toBe("scout: failed")
  })

  it("nothing for a run that succeeded, was skipped (machine_not_running) or cancelled, or has no creator", () => {
    for (const state of ["succeeded", "skipped", "cancelled", "running"]) expect(failureNotice(run({ state }), { name: "s", created_by: "u" })).toBeNull()
    expect(failureNotice(run({ state: "skipped", error: { code: "machine_not_running", message: "x" } }), { name: "s", created_by: "u" })).toBeNull()
    expect(failureNotice(run({}), { name: "s", created_by: undefined })).toBeNull()
  })
})

describe("the scheduler may post to a Feed", () => {
  it("a scheduler's system principal posts notices only, to the named user's Feed", () => {
    const p = { identity: "system:scheduler:team_1", kind: "system", user: "user_1" } as const
    expect(schedulerPoster(p, "feed.post", { type: "notice" })).toBe(true)
    expect(schedulerPoster(p, "feed.post", { type: "request" })).toBe(false)
    expect(schedulerPoster(p, "feed.ack", { type: "notice" })).toBe(false)
    expect(schedulerPoster({ ...p, identity: "system:connections:team_1" }, "feed.post", { type: "notice" })).toBe(false)
    expect(schedulerPoster({ identity: "system:scheduler:team_1", kind: "system" } as never, "feed.post", { type: "notice" })).toBe(false)
  })
})

// End to end in workerd: SchedulerDO's run.report -> its outbox -> the creator's FeedDO.
import { env as wenv, exports as wexports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { fireAlarm } from "./setup/alarm.ts"

const testEnv = wenv as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; SCHEDULER_DO: DurableObjectNamespace }
const worker = (wexports as unknown as { default: Fetcher }).default
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
const call = async (path: string, t: string, body: unknown) =>
  (await (await worker.fetch(`https://api.test${path}`, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${t}` }, body: JSON.stringify(body) })).json()) as any
const op = (t: string, name: string, params: unknown) => call("/v1/ops", t, { op: name, params, idempotency_key: crypto.randomUUID(), origin: "user" })
const read = (t: string, name: string, params: unknown = {}) => call("/v1/read", t, { op: name, params })

describe("a failed Cloud run reaches its creator's Feed (workerd)", { timeout: 60_000 }, () => {
  it("exit 3 posts one notice; a run skipped as machine_not_running posts none", async () => {
    const t = await token("auto-notice-1")
    const team = (await op(t, "user.ensure", {})).value.personal_team as string
    const created = await op(t, "automation.create", { name: "models-scout", triggers: [{ type: "webhook" }], body: { type: "steps", steps: [{ type: "note", text: "hi" }] } })
    expect(created.ok, JSON.stringify(created)).toBe(true)
    const scheduler = testEnv.SCHEDULER_DO.get(testEnv.SCHEDULER_DO.idFromName(team))
    const runs: Array<string> = []
    await inDO(scheduler, async (s) => {
      await s.ensureRunPolicy(team)
      for (const d of ["d-fail", "d-skip"]) {
        const r = s.submitSystem("automation.deliver", { automation: created.value.id, trigger: created.value.triggers[0].id, delivery_id: d }, `deliver-${d}`)
        runs.push(r.frames.find((f: { t: string }) => f.t === "result").value.id as string)
      }
      expect(await s.reportRun(team, { run: runs[0], state: "failed", step: 1, error: { code: "machine.exit", message: "step 2: exit 3: 2 of 40 models failed" } })).toMatchObject({ ok: true })
      expect(await s.reportRun(team, { run: runs[1], state: "skipped", step: 0, error: { code: "machine_not_running", message: "step 0: vm is not running and did not start" } })).toMatchObject({ ok: true })
    })
    for (let i = 0; i < 3; i++) await fireAlarm(scheduler)
    const items = (await read(t, "feed.list")).value.items as Array<any>
    const notices = items.filter((x) => x.thread === `automation:${created.value.id}`)
    expect(notices, JSON.stringify(items)).toHaveLength(1)
    expect(notices[0]).toMatchObject({ type: "notice", title: "models-scout: a check failed", priority: "high" })
    expect(notices[0].body).toContain(runs[0])
  })
})
