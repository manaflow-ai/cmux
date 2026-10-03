import { env, exports } from "cloudflare:workers"
import { introspectWorkflowInstance, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test"
import type { Principal } from "@cmux/ownership"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { egressTest, hostAllowed } from "../src/automation-egress.ts"
import { testBundles } from "../src/code-run.ts"
import { EGRESS_PER_MINUTE } from "../src/usage-meter-do.ts"

/** Slice 4 (plans/cmux-next/automations-plan.md): env.cmux, the egress gateway and the op step type. */

const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; SCHEDULER_DO: DurableObjectNamespace; USAGE_METER_DO: DurableObjectNamespace; AUTOMATION_RUN: Workflow }
const worker = (exports as unknown as { default: Fetcher }).default
const inDO = runInDurableObject as unknown as (stub: unknown, cb: (instance: any) => Promise<void>) => Promise<void>

const token = async (u: string) =>
  new SignJWT({ email: `${u}@example.com`, name: u })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(u)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))
const call = async (path: string, t: string, body: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${t}` }, body: JSON.stringify(body) })
  return (await res.json()) as any
}
const op = (t: string, name: string, params: unknown) => call("/v1/ops", t, { op: name, params, idempotency_key: crypto.randomUUID(), origin: "cli" })
const read = (t: string, name: string, params: unknown = {}) => call("/v1/read", t, { op: name, params })
const sha = (n: number) => (0xa000 + n).toString(16).padStart(40, "0")
const steps = { type: "steps", steps: [{ type: "note", text: "target" }] }

/** Creates an automation straight through the owner (no code storage here), runs it once to its end. */
const setup = async (user: string) => {
  const t = await token(user)
  const team = (await op(t, "user.ensure", {})).value.personal_team as string
  const scheduler = testEnv.SCHEDULER_DO.get(testEnv.SCHEDULER_DO.idFromName(team))
  const principal: Principal = { identity: `session:${user}`, kind: "session", user: "user_cccccccccccccccccccc", team }
  const create = async (name: string, body: unknown) => {
    let id = ""
    await inDO(scheduler, async (s) => {
      const r = await s.submit(team, principal, { t: "op", op: "automation.create", params: { name, triggers: [{ type: "manual" }], body }, idempotency_key: `create-${user}-${name}`, origin: "cli" })
      const result = r.frames.find((f: { t: string }) => f.t === "result" || f.t === "reject")
      expect(result.t, JSON.stringify(result)).toBe("result")
      id = result.value.id
    })
    return id
  }
  const runToEnd = async (automation: string) => {
    const run = await op(t, "automation.run", { automation })
    expect(run.ok, JSON.stringify(run)).toBe(true)
    const instance = await introspectWorkflowInstance(testEnv.AUTOMATION_RUN, run.value.id)
    try {
      await runDurableObjectAlarm(scheduler)
      await instance.waitForStatus("complete")
    } finally {
      await instance[Symbol.asyncDispose]()
    }
    const runs = await read(t, "automation.runs.list", { automation })
    return runs.value.runs.find((r: { id: string }) => r.id === run.value.id)
  }
  return { t, team, create, runToEnd }
}
const quantity = async (t: string, meter: string) => (await read(t, "usage.summary")).value.meters.find((x: { meter: string }) => x.meter === meter)?.quantity ?? 0

describe("egress allowlist (pure)", () => {
  it("matches exact hosts and subdomain patterns only", () => {
    expect(hostAllowed("api.example.com", ["api.example.com"])).toBe(true)
    expect(hostAllowed("x.api.example.com", ["api.example.com"])).toBe(false)
    expect(hostAllowed("a.example.com", ["*.example.com"])).toBe(true)
    expect(hostAllowed("example.com", ["*.example.com"])).toBe(false)
    expect(hostAllowed("badexample.com", ["*.example.com"])).toBe(false)
    expect(hostAllowed("api.example.com.", ["api.example.com"])).toBe(false)
  })
})

describe("slice 4 capabilities (workerd)", { timeout: 60_000 }, () => {
  it("lets code reach only allowlisted HTTPS hosts and meters each allowed request", async () => {
    const seen: Array<string> = []
    egressTest.upstream = async (url) => {
      seen.push(url)
      return new Response("pong")
    }
    try {
      const s = await setup("caps-egress")
      testBundles.set(`${sha(1)}:automations/net`, `
        import { WorkflowEntrypoint } from "cloudflare:workers";
        export default class extends WorkflowEntrypoint {
          async run(event, step) {
            return await step.do("net", async () => {
              const ok = await fetch("https://api.example.com/ping");
              const other = await fetch("https://evil.example.org/");
              const plain = await fetch("http://api.example.com/");
              const port = await fetch("https://api.example.com:8443/");
              const out = [ok.status, await ok.text(), other.status, (await other.json()).error.code, plain.status, port.status];
              if (JSON.stringify(out) !== JSON.stringify([200, "pong", 403, "egress.denied", 403, 403])) throw new Error(JSON.stringify(out));
              return out;
            });
          }
        }`)
      const id = await s.create("net", { type: "code", ref: { commit: sha(1), path: "automations/net" }, egress: ["api.example.com"] })
      const run = await s.runToEnd(id)
      expect(run, JSON.stringify(run)).toMatchObject({ state: "succeeded" })
      expect(seen).toEqual(["https://api.example.com/ping"])
      expect(await quantity(s.t, "egress.requests")).toBe(1)
    } finally {
      egressTest.upstream = undefined
    }
  })

  it("refuses egress past the per-minute limit without recording it", async () => {
    const s = await setup("caps-rate")
    await inDO(testEnv.USAGE_METER_DO.get(testEnv.USAGE_METER_DO.idFromName(s.team)), async (m) => {
      for (let i = 0; i < EGRESS_PER_MINUTE; i++) expect((await m.egress(s.team, `egress:k${i}`, Date.now())).limited).toBe(false)
      expect(await m.egress(s.team, "egress:over", Date.now())).toMatchObject({ limited: true })
    })
    expect(await quantity(s.t, "egress.requests")).toBe(EGRESS_PER_MINUTE)
  })

  it("env.cmux runs capability ops as the automation: reads, keyed mutations once, refusals", async () => {
    const s = await setup("caps-op")
    const target = await s.create("target", steps)
    testBundles.set(`${sha(2)}:automations/caller`, `
      import { WorkflowEntrypoint } from "cloudflare:workers";
      export default class extends WorkflowEntrypoint {
        async run(event, step) {
          const cmux = this.env.cmux;
          return await step.do("calls", async () => {
            const list = await cmux.op("automation.list", {});
            const a = await cmux.op("automation.run", { automation: ${JSON.stringify(target)} }, { idempotency_key: "kick" });
            const b = await cmux.op("automation.run", { automation: ${JSON.stringify(target)} }, { idempotency_key: "kick" });
            const errs = [];
            for (const f of [() => cmux.op("automation.run", { automation: ${JSON.stringify(target)} }), () => cmux.op("usage.cap.set", { cap_usd: 0 }, { idempotency_key: "cap" }), () => cmux.op("automation.get", { automation: 5 })]) {
              try { await f(); errs.push("none"); } catch (e) { errs.push(String(e.message).split(":")[0]); }
            }
            await cmux.log("info", "hello", { n: 1 });
            const out = { names: list.automations.map((x) => x.name).sort(), same: a.id === b.id, errs };
            const want = { names: ["caller", "target"], same: true, errs: ["validation.invalid", "capability.denied", "validation.invalid"] };
            if (JSON.stringify(out) !== JSON.stringify(want)) throw new Error(JSON.stringify(out));
            return out;
          });
        }
      }`)
    const caller = await s.create("caller", { type: "code", ref: { commit: sha(2), path: "automations/caller" } })
    const run = await s.runToEnd(caller)
    expect(run, JSON.stringify(run)).toMatchObject({ state: "succeeded" })
    const targetRuns = (await read(s.t, "automation.runs.list", { automation: target })).value.runs
    expect(targetRuns).toHaveLength(1)
  })

  it("the op step runs a capability op once and checks params at create", async () => {
    const s = await setup("caps-step")
    const target = await s.create("target", steps)
    const caller = await s.create("caller", { type: "steps", steps: [{ type: "op", op: "automation.run", params: { automation: target } }, { type: "note", text: "after" }] })
    const run = await s.runToEnd(caller)
    expect(run, JSON.stringify(run)).toMatchObject({ state: "succeeded" })
    expect((await read(s.t, "automation.runs.list", { automation: target })).value.runs).toHaveLength(1)
    const bad = await op(s.t, "automation.create", { name: "bad", triggers: [{ type: "manual" }], body: { type: "steps", steps: [{ type: "op", op: "automation.run", params: { automation: 7 } }] } })
    expect(bad).toMatchObject({ ok: false, error: { code: "validation.invalid" } })
    const notCap = await op(s.t, "automation.create", { name: "bad2", triggers: [{ type: "manual" }], body: { type: "steps", steps: [{ type: "op", op: "usage.cap.set", params: { cap_usd: 0 } }] } })
    expect(notCap).toMatchObject({ ok: false, error: { code: "validation.invalid" } })
  })
})
