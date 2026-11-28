import { env, exports } from "cloudflare:workers"
import { introspectWorkflowInstance, runInDurableObject } from "cloudflare:test"
import type { Principal } from "@cmux/ownership"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { automationPrincipal } from "../src/automation-caps.ts"
import { testBundles } from "../src/code-run.ts"
import { fireAlarm } from "./setup/alarm.ts"
// Route tests: drive the API Worker over HTTP; restored by the unit-test lane (slice 5 deleted them by mistake).

/** Slice 3 (plans/cmux-next/automations-plan.md): Tier 1 code runs in a Dynamic Worker, metered and capped. */

const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; SCHEDULER_DO: DurableObjectNamespace; AUTOMATION_RUN: Workflow }
const worker = (exports as unknown as { default: Fetcher }).default
const inDO = runInDurableObject as unknown as (stub: unknown, cb: (instance: any) => Promise<void>) => Promise<void>

const token = async (stackUser: string) => {
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
const call = async (path: string, t: string, body: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${t}` }, body: JSON.stringify(body) })
  return (await res.json()) as any
}
const op = (t: string, name: string, params: unknown) => call("/v1/ops", t, { op: name, params, idempotency_key: crypto.randomUUID(), origin: "cli" })
const read = (t: string, name: string, params: unknown = {}) => call("/v1/read", t, { op: name, params })

const sha = (n: number) => n.toString(16).padStart(40, "0")

/**
 * A code automation created straight through the owner (the deployment under test has no
 * code storage, so the Worker's commit check would refuse it), then run once to its end.
 */
const runOnce = async (user: string, commit: string, bundle: string, before?: (t: string) => Promise<void>) => {
  const t = await token(user)
  const ensured = await op(t, "user.ensure", {})
  const team = ensured.value.personal_team as string
  testBundles.set(`${commit}:automations/digest`, bundle)
  const scheduler = testEnv.SCHEDULER_DO.get(testEnv.SCHEDULER_DO.idFromName(team))
  let automation = ""
  const principal: Principal = { identity: `session:${user}`, kind: "session", user: "user_cccccccccccccccccccc", team }
  await inDO(scheduler, async (s) => {
    const r = await s.submit(team, principal, { t: "op", op: "automation.create", params: { name: "digest", triggers: [{ type: "manual" }], body: { type: "code", ref: { commit, path: "automations/digest" } } }, idempotency_key: `create-${user}`, origin: "cli" })
    const result = r.frames.find((f: { t: string }) => f.t === "result")
    expect(result, JSON.stringify(r.frames)).toBeDefined()
    automation = result.value.id
  })
  if (before) await before(t)
  const run = await op(t, "automation.run", { automation })
  expect(run.ok, JSON.stringify(run)).toBe(true)
  const runId = run.value.id as string
  const instance = await introspectWorkflowInstance(testEnv.AUTOMATION_RUN, runId)
  try {
    await fireAlarm(scheduler)
    await instance.waitForStatus("complete")
  } finally {
    await instance[Symbol.asyncDispose]()
  }
  const runs = await read(t, "automation.runs.list", { automation })
  return { t, team, run: runs.value.runs.find((r: { id: string }) => r.id === runId) }
}

describe("Tier 1 code runs (workerd)", () => {
  it("runs the tenant's steps in a Dynamic Worker and meters them in the team ledger", async () => {
    const bundle = `
      import { WorkflowEntrypoint } from "cloudflare:workers";
      export default class extends WorkflowEntrypoint {
        async run(event, step) {
          const a = await step.do("one", async () => 20);
          const b = await step.do("two", async () => a + 1);
          console.log("digest done", b);
          return b;
        }
      }`
    const { t, run } = await runOnce("code-run-1", sha(1), bundle)
    expect(run).toMatchObject({ state: "succeeded", error: null })
    const usage = await read(t, "usage.summary")
    const line = (m: string) => usage.value.meters.find((x: { meter: string }) => x.meter === m)
    expect(line("automation.steps").quantity).toBe(2)
    expect(line("automation.invocations").quantity).toBe(1)
    expect(line("automation.dynamic_workers").quantity).toBe(1)
  })

  it("meters each invocation although tenant code patches console.log and the array iterator", async () => {
    // Two runs of the same code share one warm Dynamic Worker; a forged marker would make them one key.
    const bundle = `
      import { WorkflowEntrypoint } from "cloudflare:workers";
      const fixed = ["cmux.run", "run_aaaaaaaaaaaaaaaaaaaa", "auto_aaaaaaaaaaaaaaaaaaaa", "inv_aaaaaaaaaaaaaaaaaaaa"];
      Array.prototype[Symbol.iterator] = function* () { yield* fixed; };
      console.log = () => {};
      export default class extends WorkflowEntrypoint {
        async run(event, step) { return await step.do("a", async () => 1); }
      }`
    const first = await runOnce("code-run-9", sha(9), bundle)
    const second = await runOnce("code-run-9", sha(9), bundle)
    expect([first.run.state, second.run.state]).toEqual(["succeeded", "succeeded"])
    const usage = await read(second.t, "usage.summary")
    expect(usage.value.meters.find((x: { meter: string }) => x.meter === "automation.invocations").quantity).toBe(2)
  })

  it("meters the first invocation although tenant module code logs while it loads", async () => {
    const bundle = `
      import { WorkflowEntrypoint } from "cloudflare:workers";
      console.log("cmux.run", "run_aaaaaaaaaaaaaaaaaaaa", "auto_aaaaaaaaaaaaaaaaaaaa", "inv_aaaaaaaaaaaaaaaaaaaa");
      export default class extends WorkflowEntrypoint {
        async run(event, step) { return await step.do("a", async () => 1); }
      }`
    const { t, team, run } = await runOnce("code-run-10", sha(10), bundle)
    expect(run.state).toBe("succeeded")
    const usage = await read(t, "usage.summary")
    const line = (m: string) => usage.value.meters.find((x: { meter: string }) => x.meter === m)
    expect(line("automation.invocations").quantity).toBe(1)
    // The ledger row carries this run's id and a harness invocation id, never the forged marker.
    const meter = (env as unknown as { USAGE_METER_DO: DurableObjectNamespace }).USAGE_METER_DO
    let rows: Array<{ key: string; run: string }> = []
    await inDO(meter.get(meter.idFromName(team)), async (m) => {
      rows = m.ctx.storage.sql.exec("SELECT key, run FROM usage_ledger WHERE meter = 'automation.invocations'").toArray()
    })
    expect(rows).toHaveLength(1)
    expect(rows[0]!.run).toBe(run.id)
    expect(rows[0]!.key).not.toContain("inv_aaaaaaaaaaaaaaaaaaaa")
  })

  it("meters each invocation although tenant code tries to replace the harness's run", async () => {
    const bundle = `
      import { WorkflowEntrypoint } from "cloudflare:workers";
      import { CmuxHarness } from "./harness.js";
      try { CmuxHarness.prototype.run = async function () { return "free"; }; } catch {}
      try { Object.defineProperty(CmuxHarness.prototype, "run", { value: async function () { return "free"; } }); } catch {}
      export default class extends WorkflowEntrypoint {
        async run(event, step) { return await step.do("a", async () => 1); }
      }`
    const first = await runOnce("code-run-11", sha(11), bundle)
    const second = await runOnce("code-run-11", sha(11), bundle)
    expect([first.run.state, second.run.state]).toEqual(["succeeded", "succeeded"])
    const usage = await read(second.t, "usage.summary")
    expect(usage.value.meters.find((x: { meter: string }) => x.meter === "automation.invocations").quantity).toBe(2)
  })

  it("meters every occurrence of a repeated step name", async () => {
    const bundle = `
      import { WorkflowEntrypoint } from "cloudflare:workers";
      export default class extends WorkflowEntrypoint {
        async run(event, step) { let n = 0; for (let i = 0; i < 5; i++) n = await step.do("tick", async () => n + 1); await step.do("x".repeat(199), async () => 0); return n; }
      }`
    const { t, run } = await runOnce("code-run-6", sha(6), bundle)
    expect(run.state).toBe("succeeded")
    const usage = await read(t, "usage.summary")
    // Five ticks and one step with a 199-character name (its key holds a hash, never the name).
    expect(usage.value.meters.find((x: { meter: string }) => x.meter === "automation.steps").quantity).toBe(6)
  })

  it("keeps the harness stop when tenant code catches it, and ignores spoofed error names", async () => {
    const caught = `
      import { WorkflowEntrypoint } from "cloudflare:workers";
      export default class extends WorkflowEntrypoint {
        async run(event, step) { try { await step.do("cmux:x", async () => 1); } catch {} return "fine"; }
      }`
    const a = await runOnce("code-run-7", sha(7), caught)
    expect(a.run).toMatchObject({ state: "failed", error: { code: "step.invalid" } })
    const spoof = `
      import { WorkflowEntrypoint } from "cloudflare:workers";
      export default class extends WorkflowEntrypoint {
        async run(event, step) { throw Object.assign(new Error("fake"), { name: "budget.cap_reached" }); }
      }`
    const b = await runOnce("code-run-8", sha(8), spoof)
    expect(b.run).toMatchObject({ state: "failed", error: { code: "run.failed" } })
  })

  it("refuses reserved step names and fails the run with step.invalid", async () => {
    const bundle = `
      import { WorkflowEntrypoint } from "cloudflare:workers";
      export default class extends WorkflowEntrypoint {
        async run(event, step) { await step.do("cmux:sneaky", async () => 1); }
      }`
    const { run } = await runOnce("code-run-2", sha(2), bundle)
    expect(run.state).toBe("failed")
    expect(run.error.message).toContain("reserved")
  })

  it("does not start tenant code when the team is at its hard cap", async () => {
    const bundle = `
      import { WorkflowEntrypoint } from "cloudflare:workers";
      export default class extends WorkflowEntrypoint { async run(event, step) { await step.do("x", async () => 1); } }`
    const { t, run } = await runOnce("code-run-3", sha(3), bundle, async (tok) => {
      expect((await op(tok, "usage.cap.set", { cap_usd: 0 })).ok).toBe(true)
    })
    expect(run).toMatchObject({ state: "failed", error: { code: "budget.cap_reached" } })
    const usage = await read(t, "usage.summary")
    expect(usage.value.meters.find((x: { meter: string }) => x.meter === "automation.steps").quantity).toBe(0)
  })

  it("does not start tenant code when the automation owner is at their monthly AI limit (cx-ds09i)", async () => {
    const bundle = `
      import { WorkflowEntrypoint } from "cloudflare:workers";
      export default class extends WorkflowEntrypoint { async run(event, step) { await step.do("x", async () => 1); } }`
    const { t, run } = await runOnce("code-run-12", sha(12), bundle, async (tok) => {
      // The owner (creator of the automation) sets their personal team's per-member limit to 0.
      expect((await op(tok, "team.ai_limit.set", { default_usd: 0 })).ok).toBe(true)
    })
    expect(run).toMatchObject({ state: "failed", error: { code: "user_limit.reached" } })
    const usage = await read(t, "usage.summary")
    expect(usage.value.meters.find((x: { meter: string }) => x.meter === "automation.steps").quantity).toBe(0)
  })

  it("charges a manual run to the member who started it, not to the automation's creator (cx-ds09i review P2)", async () => {
    const bundle = `
      import { WorkflowEntrypoint } from "cloudflare:workers";
      export default class extends WorkflowEntrypoint { async run(event, step) { await step.do("x", async () => 1); } }`
    const { team, run } = await runOnce("code-run-13", sha(13), bundle)
    expect(run.state).toBe("succeeded")
    const meter = (env as unknown as { USAGE_METER_DO: DurableObjectNamespace }).USAGE_METER_DO.get((env as unknown as { USAGE_METER_DO: DurableObjectNamespace }).USAGE_METER_DO.idFromName(team))
    let users: Array<string> = []
    await inDO(meter, async (m) => {
      users = m.ctx.storage.sql.exec(`SELECT user FROM user_month WHERE usd_micros > 0`).toArray().map((r: { user: string }) => r.user)
    })
    // runOnce creates the automation as user_cccc... and starts the run with the token of the "code-run-13" user.
    expect(users.length).toBe(1)
    expect(users[0]).not.toBe("user_cccccccccccccccccccc")
    expect(users[0]).toMatch(/^user_[0-9a-f]{20}$/)
  })

  it("an effective automation.update makes the editor the payer; a rename does not (cx-ds09i review P2)", async () => {
    const t = await token("code-run-14")
    const team = (await op(t, "user.ensure", {})).value.personal_team as string
    const scheduler = testEnv.SCHEDULER_DO.get(testEnv.SCHEDULER_DO.idFromName(team))
    const as = (user: string): Principal => ({ identity: `session:${user}`, kind: "session", user, team })
    const submit = async (s: any, p: Principal, opName: string, params: unknown) => {
      const r = await s.submit(team, p, { t: "op", op: opName, params, idempotency_key: crypto.randomUUID(), origin: "cli" })
      return r.frames.find((f: { t: string }) => f.t === "result")?.value
    }
    await inDO(scheduler, async (s) => {
      const a = await submit(s, as("user_aaaaaaaaaaaaaaaaaaaa"), "automation.create", { name: "pay", triggers: [{ type: "manual" }], body: { type: "steps", steps: [{ type: "note", text: "x" }] } })
      const head = () => s.boundEngine.currentState.charged_to?.[a.id]
      expect(head()).toBe("user_aaaaaaaaaaaaaaaaaaaa")
      await submit(s, as("user_bbbbbbbbbbbbbbbbbbbb"), "automation.update", { automation: a.id, name: "renamed" })
      expect(head()).toBe("user_aaaaaaaaaaaaaaaaaaaa")
      await submit(s, as("user_bbbbbbbbbbbbbbbbbbbb"), "automation.update", { automation: a.id, concurrency: { max: 2, on_limit: "queue" } })
      expect(head()).toBe("user_bbbbbbbbbbbbbbbbbbbb")
    })
  })

  it("a run started by an automation is charged to the member who pays for the parent run (cx-ds09i review P2)", async () => {
    const t = await token("code-run-15")
    const team = (await op(t, "user.ensure", {})).value.personal_team as string
    const scheduler = testEnv.SCHEDULER_DO.get(testEnv.SCHEDULER_DO.idFromName(team))
    const person: Principal = { identity: "session:user_cccccccccccccccccccc", kind: "session", user: "user_cccccccccccccccccccc", team }
    const submit = async (s: any, p: Principal, opName: string, params: unknown) => {
      const r = await s.submit(team, p, { t: "op", op: opName, params, idempotency_key: crypto.randomUUID(), origin: "cli" })
      return r.frames.find((f: { t: string }) => f.t === "result")?.value ?? r.frames
    }
    await inDO(scheduler, async (s) => {
      const body = { type: "steps", steps: [{ type: "note", text: "x" }] }
      const parentAuto = await submit(s, person, "automation.create", { name: "parent", triggers: [{ type: "manual" }], body })
      const child = await submit(s, person, "automation.create", { name: "child", triggers: [{ type: "manual" }], body })
      const parentRun = await submit(s, { ...person, identity: "session:user_dddddddddddddddddddd", user: "user_dddddddddddddddddddd" }, "automation.run", { automation: parentAuto.id })
      // The parent run's own principal, as its capability calls carry it (automation-caps.ts).
      const auto = automationPrincipal({ automation: parentAuto.id, run: parentRun.id, team } as never)
      const childRun = await submit(s, auto, "automation.run", { automation: child.id })
      const row = (s.rows ?? s.boundEngine?.rows)?.get("run", childRun.id)?.row
      expect(row?.charged_user, JSON.stringify(childRun)).toBe("user_dddddddddddddddddddd")
    })
  })

  it("fails with code.not_found when the bundle is missing, and the tenant has no network", async () => {
    const missing = await runOnce("code-run-4", sha(4), "", async () => {
      testBundles.delete(`${sha(4)}:automations/digest`)
    })
    expect(missing.run).toMatchObject({ state: "failed", error: { code: "code.not_found" } })
    const bundle = `
      import { WorkflowEntrypoint } from "cloudflare:workers";
      export default class extends WorkflowEntrypoint {
        async run(event, step) { await step.do("fetch", { retries: { limit: 0, delay: 1 } }, async () => (await fetch("https://example.com")).status); }
      }`
    const { run } = await runOnce("code-run-5", sha(5), bundle)
    expect(run.state).toBe("failed")
  })
})
