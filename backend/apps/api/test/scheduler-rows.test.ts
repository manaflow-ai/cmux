import { createHash } from "node:crypto"
import { canonicalJson } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { SYSTEM, USER, withSchedulerEngine, type Harness } from "./setup/scheduler-engine.ts"

/**
 * (g1) SchedulerDO automations, runs and bodies live in rows, not in the 2 MB JSON head
 * (plans/cmux-next/backend.md section (g), DO audit F-1).
 */

const hashOf = (body: unknown) => createHash("sha256").update(canonicalJson(body)).digest("hex")
const steps = (text: string) => ({ type: "steps", steps: [{ type: "note", text }] })
const agent = (i: number) => ({ type: "agent_prompt", instructions: `${i}:`.padEnd(20_000, String.fromCharCode(97 + (i % 26))), workspace: { mode: "fresh_worktree" }, conversation: "fresh" })

/** One run of `automation`; the clock moves a second so the team's creation bucket refills. */
const run = (h: Harness, automation: string): { id: string; state: string } => {
  h.tick(1000)
  return h.op(USER, "automation.run", { automation })
}
const finish = (h: Harness, id: string) => h.op(SYSTEM, "run.report", { run: id, state: "succeeded", step: 0 })

describe("SchedulerDO head size (g1)", { timeout: 300_000 }, () => {
  it("100 automations with 20,000-character instructions and 450 kept runs commit with a head under 100 KB", async () => {
    await withSchedulerEngine("size", (h) => {
      const ids: Array<string> = []
      for (let i = 0; i < 100; i++) ids.push(h.op(USER, "automation.create", { name: `a${i}`, triggers: [{ type: "manual" }], body: agent(i) }).id)
      // 260 finished runs: the newest 200 stay, 60 are pruned.
      for (let i = 0; i < 260; i++) finish(h, run(h, ids[i % 100]!).id)
      // 250 open runs (the team's open-run limit).
      for (let i = 0; i < 250; i++) expect(run(h, ids[i % 100]!).state).toBe("queued")
      expect(() => run(h, ids[0]!)).toThrow(/rate.limited/)
      const head = h.headJson()
      expect(head.length).toBeLessThan(100_000)
      const parsed = JSON.parse(head)
      expect(parsed.automations).toBeUndefined()
      expect(parsed.runs).toBeUndefined()
      expect(parsed.automation_count).toBe(100)
      expect(parsed.finished_count).toBe(200)
      expect(parsed.open_runs).toHaveLength(250)
      expect(h.rows("automation")).toHaveLength(100)
      expect(h.rows("run")).toHaveLength(450)
      expect(h.rows("finished")).toHaveLength(200)
      expect(h.rows("body")).toHaveLength(100)
      // No row holds a body except the body rows.
      for (const r of [...h.rows("automation"), ...h.rows("run")]) expect(r.json.body).toBeUndefined()
      // The next commit still fits.
      h.op(USER, "automation.update", { automation: ids[0], name: "renamed" })
      expect(h.headJson().length).toBeLessThan(100_000)
    })
  })
})

describe("SchedulerDO bodies are stored once and counted (g1)", { timeout: 300_000 }, () => {
  it("a body shared by an automation and its runs survives an edit until the last run that uses it is pruned", async () => {
    await withSchedulerEngine("bodies", (h) => {
      const a = h.op(USER, "automation.create", { name: "a", triggers: [{ type: "manual" }], body: steps("x"), concurrency: { max: 5, on_limit: "queue" } })
      const x = hashOf(a.body)
      const r1 = run(h, a.id)
      // One body row for the automation and its run.
      expect(h.rows("body").map((r) => r.k)).toEqual([x])
      expect(h.row("body", x)).toMatchObject({ refs: 2, body: a.body })
      expect(h.row("run", r1.id)).toMatchObject({ body_hash: x })
      finish(h, r1.id)
      const edited = h.op(USER, "automation.update", { automation: a.id, body: steps("y") })
      const y = hashOf(edited.body)
      expect(y).not.toBe(x)
      // The started run keeps its body; the automation points at the new one.
      expect(h.row("run", r1.id)).toMatchObject({ body_hash: x })
      expect(h.row("automation", a.id)).toMatchObject({ body_hash: y })
      expect(h.row("body", x)).toMatchObject({ refs: 1 })
      expect(h.row("body", y)).toMatchObject({ refs: 1 })
      const r2 = run(h, a.id)
      expect(h.row("run", r2.id)).toMatchObject({ body_hash: y })
      finish(h, r2.id)
      // 198 more finished runs: r1 is still among the newest 200, so x stays.
      for (let i = 0; i < 198; i++) finish(h, run(h, a.id).id)
      expect(h.row("run", r1.id)).toBeDefined()
      expect(h.row("body", x)).toMatchObject({ refs: 1 })
      // One more: r1 is pruned, and with it the last reference to x.
      finish(h, run(h, a.id).id)
      expect(h.row("run", r1.id)).toBeUndefined()
      expect(h.row("body", x)).toBeUndefined()
      expect(h.row("body", y)).toMatchObject({ refs: 201 })
      // Deleting the automation leaves the body to its kept runs.
      h.op(USER, "automation.delete", { automation: a.id })
      expect(h.row("automation", a.id)).toBeUndefined()
      expect(h.row("body", y)).toMatchObject({ refs: 200 })
      // An edit back to an earlier body text stores it again once.
      const b = h.op(USER, "automation.create", { name: "b", triggers: [{ type: "manual" }], body: steps("x") })
      expect(h.row("body", x)).toMatchObject({ refs: 1, body: b.body })
    })
  })
})

describe("SchedulerDO cancel on disable, delete and deny (g1)", { timeout: 300_000 }, () => {
  it("disable, delete and a policy deny cancel every queued run without a Workflow", async () => {
    await withSchedulerEngine("cancel", (h) => {
      const make = (name: string) => h.op(USER, "automation.create", { name, triggers: [{ type: "manual" }], body: steps(name), concurrency: { max: 1, on_limit: "queue" } }).id as string
      const a = make("a")
      const started = run(h, a).id
      h.op(SYSTEM, "run.dispatched", { run: started })
      const queued: Array<string> = []
      for (let i = 0; i < 40; i++) queued.push(run(h, a).id)
      h.op(USER, "automation.update", { automation: a, enabled: false })
      for (const id of queued) expect(h.row("run", id)).toMatchObject({ state: "cancelled", error: { code: "automation.stopped" } })
      expect(h.row("run", started)).toMatchObject({ state: "queued", dispatched: true })
      expect(JSON.parse(h.headJson()).open_runs).toEqual([started])

      const b = make("b")
      const bq: Array<string> = []
      for (let i = 0; i < 30; i++) bq.push(run(h, b).id)
      h.op(USER, "automation.delete", { automation: b })
      for (const id of bq) expect(h.row("run", id)).toMatchObject({ state: "cancelled" })

      const c = make("c")
      const cq: Array<string> = []
      for (let i = 0; i < 20; i++) cq.push(run(h, c).id)
      h.op(SYSTEM, "scheduler.run_policy", { version: 2, runs_allowed: false })
      for (const id of cq) expect(h.row("run", id)).toMatchObject({ state: "cancelled" })
      expect(JSON.parse(h.headJson()).open_runs).toEqual([started])
      expect(JSON.parse(h.headJson()).finished_count).toBe(90)
    })
  })
})
