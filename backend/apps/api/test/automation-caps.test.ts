import { env, exports } from "cloudflare:workers"
import { introspectWorkflowInstance, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test"
import type { Principal } from "@cmux/ownership"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { egressTest, hostAllowed } from "../src/automation-egress.ts"
import { testBundles } from "../src/code-run.ts"
import { EGRESS_PER_MINUTE } from "../src/usage-meter-do.ts"
import { automationTrigger, MAX_TREE_RUNS } from "../src/domains/scheduler-chain.ts"

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

describe("automation run trees (pure)", () => {
  it("caps each tree, keeps depth, and drops counters of trees with no run left", () => {
    const run = (id: string, automation: string, trigger: Record<string, unknown>) => ({ id, automation, state: "running", trigger: { id: null, ...trigger } })
    const target = { body: { type: "steps" } } as any
    const p = { kind: "agent", identity: "automation:auto_a", agent: "auto_a", run: "run_root", team: "t" } as any
    const state: any = { runs: { run_root: run("run_root", "auto_a", { type: "manual" }) }, automation_trees: { run_root: MAX_TREE_RUNS - 1, run_gone: 3 } }
    const ok = automationTrigger(state, p, target) as any
    expect(ok.trigger).toMatchObject({ type: "automation", parent_run: "run_root", root_run: "run_root", depth: 1 })
    expect(ok.trees).toEqual({ run_root: MAX_TREE_RUNS })
    expect(automationTrigger({ ...state, automation_trees: ok.trees }, p, target)).toMatchObject({ ok: false, code: "automation.fanout" })
    // A run reached through leaked capabilities still counts against its own tree.
    const deep: any = { runs: { run_c: run("run_c", "auto_a", { type: "automation", parent_run: "run_root", root_run: "run_root", depth: 3 }) }, automation_trees: {} }
    expect(automationTrigger(deep, { ...p, run: "run_c" }, target)).toMatchObject({ ok: false, code: "automation.depth" })
    expect(automationTrigger(state, { ...p, agent: "auto_b" }, target)).toMatchObject({ ok: false, code: "auth.forbidden" })
    // A pruned root keeps its counter while a child of its tree is still in state.
    const child = run("run_c", "auto_a", { type: "automation", parent_run: "run_root", root_run: "run_root", depth: 1 })
    const kept = automationTrigger({ runs: { run_c: child }, automation_trees: { run_root: MAX_TREE_RUNS } } as any, { ...p, run: "run_c" }, target)
    expect(kept).toMatchObject({ ok: false, code: "automation.fanout" })
    // An old chained record without root_run, and a finished caller, are refused.
    const old = run("run_o", "auto_a", { type: "automation", parent_run: "run_x", depth: 1 })
    expect(automationTrigger({ runs: { run_o: old } } as any, { ...p, run: "run_o" }, target)).toMatchObject({ ok: false, code: "automation.fanout" })
    expect(automationTrigger({ runs: { run_root: { ...state.runs.run_root, state: "succeeded" } } } as any, p, target)).toMatchObject({ ok: false, code: "auth.forbidden" })
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

  it("admits egress up to the per-minute limit, refuses at the cap, and counts only answered requests", async () => {
    const s = await setup("caps-rate")
    await inDO(testEnv.USAGE_METER_DO.get(testEnv.USAGE_METER_DO.idFromName(s.team)), async (m) => {
      for (let i = 0; i < EGRESS_PER_MINUTE; i++) expect((await m.egressAdmit(s.team)).limited).toBe(false)
      expect(await m.egressAdmit(s.team)).toMatchObject({ limited: true })
      // Admission counts nothing; no ledger row per request.
      expect(Number(m.ctx.storage.sql.exec("SELECT COUNT(*) AS n FROM usage_ledger WHERE meter = 'egress.requests'").toArray()[0].n)).toBe(0)
      await m.egressDone(s.team)
    })
    expect(await quantity(s.t, "egress.requests")).toBe(1)
    expect((await op(s.t, "usage.cap.set", { cap_usd: 0 })).ok).toBe(true)
    await inDO(testEnv.USAGE_METER_DO.get(testEnv.USAGE_METER_DO.idFromName(s.team)), async (m) => {
      expect(await m.egressAdmit(s.team)).toMatchObject({ allowed: false })
    })
  })

  it("never reaches cmux's own domains, strips edge headers, and refuses raw sockets", async () => {
    const seen: Array<{ url: string; headers: Array<string> }> = []
    egressTest.upstream = async (url, init) => {
      seen.push({ url, headers: [...new Headers(init.headers).keys()].sort() })
      return new Response("ok")
    }
    try {
      const s = await setup("caps-zones")
      const bad = await op(s.t, "automation.create", { name: "own", triggers: [{ type: "manual" }], body: { type: "code", ref: { commit: sha(3), path: "automations/own" }, egress: ["*.cmux.dev"] } })
      expect(bad).toMatchObject({ ok: false })
      expect(hostAllowed("api.cmux.dev", ["api.cmux.dev"])).toBe(false)
      expect(hostAllowed("x.workers.dev", ["*.workers.dev"])).toBe(false)
      testBundles.set(`${sha(4)}:automations/hdr`, `
        import { WorkflowEntrypoint } from "cloudflare:workers";
        import { connect } from "cloudflare:sockets";
        export default class extends WorkflowEntrypoint {
          async run(event, step) {
            return await step.do("hdr", async () => {
              await fetch("https://api.example.com/", { headers: { "x-ok": "1", "cf-ray": "x", "x-forwarded-host": "evil", "forwarded": "for=1", "true-client-ip": "1.2.3.4" } });
              // The socket can only reach the gateway, which closes it: no byte ever comes back.
              let sock = "refused";
              try {
                const c = connect({ hostname: "api.example.com", port: 443 });
                const w = c.writable.getWriter();
                await w.write(new TextEncoder().encode("GET / HTTP/1.0\\r\\n\\r\\n")).catch(() => {});
                const got = await c.readable.getReader().read();
                sock = got.done ? "refused" : "data";
              } catch (e) { sock = "refused"; }
              if (sock !== "refused") throw new Error("raw socket returned data");
              return sock;
            });
          }
        }`)
      const id = await s.create("hdr", { type: "code", ref: { commit: sha(4), path: "automations/hdr" }, egress: ["api.example.com"] })
      const run = await s.runToEnd(id)
      expect(run, JSON.stringify(run)).toMatchObject({ state: "succeeded" })
      expect(seen).toHaveLength(1)
      expect(seen[0]!.headers).toEqual(["x-ok"])
      // The socket reached the gateway, which refused it.
      expect(egressTest.connects).toBeGreaterThanOrEqual(1)
    } finally {
      egressTest.upstream = undefined
    }
  })

  it("bounds runs that automations start: depth, agent_prompt, and no continue reset", async () => {
    const s = await setup("caps-chain")
    // A steps automation that runs itself through an op step: depth 1, 2, 3, then refused.
    const self = await s.create("self", { type: "steps", steps: [{ type: "note", text: "x" }] })
    const updated = await op(s.t, "automation.update", { automation: self, body: { type: "steps", steps: [{ type: "op", op: "automation.run", params: { automation: self } }] } })
    expect(updated.ok, JSON.stringify(updated)).toBe(true)
    const first = await s.runToEnd(self)
    expect(first.state).toBe("succeeded")
    const scheduler = testEnv.SCHEDULER_DO.get(testEnv.SCHEDULER_DO.idFromName(s.team))
    let depths: Array<number> = []
    await inDO(scheduler, async (d) => {
      const runs = Object.values(d.boundEngine.currentState.runs) as Array<{ trigger: { type: string; depth?: number } }>
      depths = runs.filter((r) => r.trigger.type === "automation").map((r) => r.trigger.depth!).sort()
    })
    expect(depths).toEqual([1])
    // Direct reducer path for deeper levels: an automation principal of a depth-3 run is refused.
    await inDO(scheduler, async (d) => {
      const state = d.boundEngine.currentState
      const child = Object.values(state.runs).find((r: any) => r.trigger.type === "automation") as { id: string }
      state.runs[child.id] = { ...state.runs[child.id], state: "running", trigger: { ...state.runs[child.id].trigger, depth: 3 } }
      const principal = { kind: "agent", identity: `automation:${self}`, agent: self, run: child.id, team: s.team, grant_classes: ["read", "execute"] }
      const r = await d.submit(s.team, principal, { t: "op", op: "automation.run", params: { automation: self }, idempotency_key: "deep", origin: "script" })
      expect(r.frames.find((f: { t: string }) => f.t === "reject")).toMatchObject({ code: "automation.depth" })
    })
    const agent = await s.create("agent", { type: "agent_prompt", instructions: "x", workspace: { mode: "fresh_worktree" }, conversation: "fresh" })
    const caller = await s.create("caller", { type: "steps", steps: [{ type: "op", op: "automation.run", params: { automation: agent } }] })
    expect(await s.runToEnd(caller)).toMatchObject({ state: "failed", error: { code: "auth.forbidden" } })
  })

  it("a keyed mutation inside a tenant step is refused; outside a step it is a durable step that runs once", async () => {
    const s = await setup("caps-journal")
    const target = await s.create("target", steps)
    testBundles.set(`${sha(5)}:automations/j`, `
      import { WorkflowEntrypoint } from "cloudflare:workers";
      export default class extends WorkflowEntrypoint {
        async run(event, step) {
          const cmux = this.env.cmux;
          const inside = await step.do("inside", async () => {
            try { await cmux.op("automation.run", { automation: ${JSON.stringify(target)} }, { idempotency_key: "in" }); return "ran"; } catch (e) { return String(e.message).split(":")[0]; }
          });
          if (inside !== "capability.in_step") throw new Error("inside: " + inside);
          const a = await cmux.op("automation.run", { automation: ${JSON.stringify(target)} }, { idempotency_key: "out" });
          await step.sleep("nap", 1);
          const b = await cmux.op("automation.run", { automation: ${JSON.stringify(target)} }, { idempotency_key: "out" });
          if (a.id !== b.id) throw new Error("two runs");
          return a.id;
        }
      }`)
    const caller = await s.create("j", { type: "code", ref: { commit: sha(5), path: "automations/j" } })
    expect(await s.runToEnd(caller)).toMatchObject({ state: "succeeded" })
    expect((await read(s.t, "automation.runs.list", { automation: target })).value.runs).toHaveLength(1)
  })

  it("env.cmux runs capability ops as the automation: reads, keyed mutations once, refusals", async () => {
    const s = await setup("caps-op")
    const target = await s.create("target", steps)
    testBundles.set(`${sha(2)}:automations/caller`, `
      import { WorkflowEntrypoint } from "cloudflare:workers";
      export default class extends WorkflowEntrypoint {
        async run(event, step) {
          const cmux = this.env.cmux;
          // Mutations are their own durable steps, so they are called outside step.do.
          const a = await cmux.op("automation.run", { automation: ${JSON.stringify(target)} }, { idempotency_key: "kick" });
          const b = await cmux.op("automation.run", { automation: ${JSON.stringify(target)} }, { idempotency_key: "kick" });
          return await step.do("calls", async () => {
            const list = await cmux.op("automation.list", {});
            const errs = [];
            for (const f of [() => cmux.op("automation.run", { automation: ${JSON.stringify(target)} }), () => cmux.op("usage.cap.set", { cap_usd: 0 }), () => cmux.op("automation.get", { automation: 5 })]) {
              try { await f(); errs.push("none"); } catch (e) { errs.push(String(e.message).split(":")[0]); }
            }
            await cmux.log("info", "hello", { n: 1 });
            const out = { names: list.automations.map((x) => x.name).sort(), same: a.id === b.id, errs };
            const want = { names: ["caller", "target"], same: true, errs: ["validation.invalid", "validation.invalid", "validation.invalid"] };
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
