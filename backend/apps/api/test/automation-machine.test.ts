import { env } from "cloudflare:workers"
import { introspectWorkflowInstance, runInDurableObject } from "cloudflare:test"
import type { Principal } from "@cmux/ownership"
import { Step } from "@cmux/protocol"
import { Exit, Schema } from "effect"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { exports } from "cloudflare:workers"
import { invalidStepRef, machineStepCommand, machineStepStdin, runMachineStep, STEP_OUTPUT_MAX, type MachineExec } from "../src/automation-machine.ts"
import { invalidBody } from "../src/domains/scheduler-code.ts"
import { runLimitMs, RUN_GRACE_MS } from "../src/domains/scheduler-runs.ts"
import { fireAlarm } from "./setup/alarm.ts"
import { bindBody, bindFile, cloudStub } from "./cloud-bind-support.ts"
import { cloudTestUser, SHARED_TEAM } from "./setup/cloud-teams.ts"

/** Org workflows (plans/cmux-next/org-workflows-DESIGN.md): machine and agent steps on the team's own machines. */

const VM = "vm_aaaaaaaaaaaaaaaaaaaa"
const RUN = "run_bbbbbbbbbbbbbbbbbbbb"
const decodeStep = (v: unknown) => Schema.decodeUnknownExit(Step)(v)
const text = (b: Uint8Array | null) => (b ? new TextDecoder().decode(b) : null)

/** A port that records every call and answers from a script. */
const fakePort = (answer: Awaited<ReturnType<MachineExec["exec"]>>) => {
  const calls: Array<{ machine: string; command: string; stdin: string | null; timeoutMs: number }> = []
  const port: MachineExec = {
    exec: async (machine, command, stdin, timeoutMs) => {
      calls.push({ machine, command, stdin: text(stdin), timeoutMs })
      return answer
    }
  }
  return { port, calls }
}

describe("machine and agent step specs", () => {
  it("accepts a machine step and an agent step, and refuses bad machines, harnesses and timeouts", () => {
    expect(Exit.isSuccess(decodeStep({ type: "machine", machine: VM, command: "echo hi", timeout_seconds: 60 }))).toBe(true)
    expect(Exit.isSuccess(decodeStep({ type: "agent", machine: VM, harness: "claude", prompt: "Say hi", input_from: 0, timeout_seconds: 300 }))).toBe(true)
    expect(Exit.isSuccess(decodeStep({ type: "machine", machine: "vm-83d983e7", command: "echo hi", timeout_seconds: 60 }))).toBe(false)
    expect(Exit.isSuccess(decodeStep({ type: "agent", machine: VM, harness: "bash", prompt: "x", timeout_seconds: 60 }))).toBe(false)
    expect(Exit.isSuccess(decodeStep({ type: "machine", machine: VM, command: "", timeout_seconds: 60 }))).toBe(false)
    expect(Exit.isSuccess(decodeStep({ type: "machine", machine: VM, command: "x", timeout_seconds: 0 }))).toBe(false)
    // One provider exec answers within about 300 s; longer work belongs in a durable terminal.
    expect(Exit.isSuccess(decodeStep({ type: "machine", machine: VM, command: "x", timeout_seconds: 300 }))).toBe(true)
    expect(Exit.isSuccess(decodeStep({ type: "machine", machine: VM, command: "x", timeout_seconds: 301 }))).toBe(false)
  })

  it("input_from must name an earlier machine or agent step", () => {
    const m = { type: "machine", machine: VM, command: "date", timeout_seconds: 10 } as const
    const a = (from: number) => ({ type: "agent", machine: VM, harness: "claude", prompt: "p", input_from: from, timeout_seconds: 10 }) as const
    expect(invalidStepRef([m, a(0)], 1)).toBeUndefined()
    expect(invalidStepRef([m, a(1)], 1)).toMatch(/earlier/)
    expect(invalidStepRef([m, a(5)], 1)).toMatch(/earlier/)
    expect(invalidStepRef([{ type: "note", text: "n" }, a(0)], 1)).toMatch(/machine or agent/)
    // The create path refuses it too, so a broken graph fails at create, not at run time.
    expect(invalidBody({ type: "steps", steps: [m, a(1)] } as never)).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(invalidBody({ type: "steps", steps: [m, a(0)] } as never)).toBeUndefined()
  })
})

describe("deterministic commands", () => {
  const machine = { type: "machine", machine: VM, command: "git log -1 --format=%H", timeout_seconds: 30 } as const
  const agent = { type: "agent", machine: VM, harness: "codex", prompt: "Summarize; don't run $(rm -rf /)", timeout_seconds: 300 } as const

  it("the same step and run make the same command, with the run, step and idempotency key", () => {
    const c = machineStepCommand(machine, { run: RUN, index: 2 })
    expect(c).toBe(machineStepCommand(machine, { run: RUN, index: 2 }))
    expect(c).toContain(`CMUX_STEP_KEY='step:${RUN}:2'`)
    expect(c).toContain(`CMUX_RUN='${RUN}'`)
    expect(c).toContain("git log -1 --format=%H")
    expect(machineStepCommand(machine, { run: RUN, index: 3 })).not.toBe(c)
  })

  it("an agent prompt and step input go on stdin, never into the command line", () => {
    const c = machineStepCommand(agent, { run: RUN, index: 1 })
    expect(c).toContain("acpmux run -m codex --on-permission fail --timeout 290 -- \"$p\"")
    // acpmux lives in the work user's ~/.local/bin, which a login shell does not always put on PATH.
    expect(c).toContain('PATH="$HOME/.local/bin:$PATH"')
    expect(c).not.toContain("Summarize")
    expect(c).not.toContain("rm -rf")
    expect(text(machineStepStdin(agent, null))).toBe(agent.prompt)
    expect(text(machineStepStdin(agent, "abc123"))).toBe(`${agent.prompt}\n\nInput:\nabc123`)
    expect(machineStepStdin(machine, null)).toBeNull()
    expect(text(machineStepStdin(machine, "abc123"))).toBe("abc123")
  })
})

describe("run deadline", () => {
  it("covers every machine and agent step's timeout, not only sleeps", () => {
    const body = { type: "steps", steps: [{ type: "machine", machine: VM, command: "x", timeout_seconds: 300 }, { type: "agent", machine: VM, harness: "claude", prompt: "p", timeout_seconds: 200 }, { type: "sleep", seconds: 10 }] } as never
    expect(runLimitMs(body, undefined)).toBe((300 + 200 + 10) * 1000 + RUN_GRACE_MS)
  })
})

describe("runMachineStep", () => {
  const step = { type: "machine", machine: VM, command: "echo ok", timeout_seconds: 7 } as const

  it("returns the journaled output (the stdout tail) and passes the timeout", async () => {
    const big = "x".repeat(STEP_OUTPUT_MAX) + "END\n"
    const { port, calls } = fakePort({ ok: true, exitCode: 0, stdout: big, stderr: "" })
    const r = await runMachineStep(port, step, { run: RUN, index: 0 }, null)
    expect(r).toEqual({ ok: true, output: big.slice(-STEP_OUTPUT_MAX) })
    expect(calls).toHaveLength(1)
    expect(calls[0]).toMatchObject({ machine: VM, timeoutMs: 7000, stdin: null })
  })

  it("maps a non-zero exit, a guest timeout and every refusal to a run error code", async () => {
    const exit = await runMachineStep(fakePort({ ok: true, exitCode: 3, stdout: "", stderr: "boom\nlast line" }).port, step, { run: RUN, index: 0 }, null)
    expect(exit).toMatchObject({ ok: false, code: "machine.exit", message: expect.stringContaining("exit 3") })
    expect(exit.ok === false && exit.message).toContain("last line")
    expect(await runMachineStep(fakePort({ ok: true, exitCode: 124, stdout: "", stderr: "" }).port, step, { run: RUN, index: 0 }, null)).toMatchObject({ ok: false, code: "machine.timeout" })
    expect(await runMachineStep(fakePort({ ok: false, refusal: "not_found" }).port, step, { run: RUN, index: 0 }, null)).toMatchObject({ ok: false, code: "machine.not_found" })
    expect(await runMachineStep(fakePort({ ok: false, refusal: "not_running" }).port, step, { run: RUN, index: 0 }, null)).toMatchObject({ ok: false, code: "machine.not_running" })
    expect(await runMachineStep(fakePort({ ok: false, refusal: "provider_failed" }).port, step, { run: RUN, index: 0 }, null)).toMatchObject({ ok: false, code: "machine.unavailable" })
    expect(await runMachineStep(fakePort({ ok: false, refusal: "forbidden" }).port, step, { run: RUN, index: 0 }, null)).toMatchObject({ ok: false, code: "machine.forbidden" })
    expect(await runMachineStep(fakePort({ ok: false, refusal: "output_limit" }).port, step, { run: RUN, index: 0 }, null)).toMatchObject({ ok: false, code: "machine.output_limit" })
  })
})

// The Workflow and the team's CloudDO, end to end in workerd: a machine the team does not have.
const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; SCHEDULER_DO: DurableObjectNamespace; AUTOMATION_RUN: Workflow }
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
const call = async (path: string, t: string, body: unknown) =>
  (await (await worker.fetch(`https://api.test${path}`, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${t}` }, body: JSON.stringify(body) })).json()) as any
const op = (t: string, name: string, params: unknown) => call("/v1/ops", t, { op: name, params, idempotency_key: crypto.randomUUID(), origin: "cli" })
const read = (t: string, name: string, params: unknown = {}) => call("/v1/read", t, { op: name, params })

describe("machine steps in a run (workerd)", { timeout: 60_000 }, () => {
  it("does not execute a shared-team machine step after its creator leaves the team", async () => {
    const user = cloudTestUser(190)
    const principal: Principal = { identity: `user:${user}`, kind: "session", user, team: SHARED_TEAM }
    const cloud = cloudStub(SHARED_TEAM)
    const created = await cloud.submit(SHARED_TEAM, principal, {
      t: "op",
      op: "cloud.machine.create",
      params: { size: { cpu: 2, memory_mb: 4096, disk_mb: 16384 } },
      idempotency_key: crypto.randomUUID(),
      origin: "user"
    })
    const machine = (created.frames.find((frame) => frame.t === "result")?.value as { machine?: { id?: string } } | undefined)?.machine?.id
    expect(machine).toMatch(/^vm_/)
    const file = await bindFile(cloud, machine!)
    const { body } = await bindBody({ user, team: SHARED_TEAM }, machine!, file.json.bind_token)

    let execCalls = 0
    const reply = await inDO(cloud, async (instance) => {
      instance.creatorIsMember = async () => true
      expect(await instance.bindMachine(SHARED_TEAM, body)).toMatchObject({ ok: true })
      instance.creatorIsMember = async () => false
      instance.driverFor = () => ({
        execStdin: async () => {
          execCalls++
          return { exitCode: 0, stdout: "should not run", stderr: "" }
        }
      })
      return instance.automationExec(SHARED_TEAM, user, machine, "echo should-not-run", null, 1000)
    })

    expect(reply).toEqual({ ok: false, refusal: "forbidden" })
    expect(execCalls).toBe(0)
  })

  it("a step on a machine the team does not have fails the run with machine.not_found", async () => {
    const t = await token("machine-step")
    const team = (await op(t, "user.ensure", {})).value.personal_team as string
    const scheduler = testEnv.SCHEDULER_DO.get(testEnv.SCHEDULER_DO.idFromName(team))
    const principal: Principal = { identity: "session:machine-step", kind: "session", user: "user_cccccccccccccccccccc", team }
    let automation = ""
    await inDO(scheduler, async (s) => {
      const r = await s.submit(team, principal, {
        t: "op",
        op: "automation.create",
        params: { name: "digest", triggers: [{ type: "manual" }], body: { type: "steps", steps: [{ type: "machine", machine: VM, command: "echo hi", timeout_seconds: 30 }] } },
        idempotency_key: "create-machine-step",
        origin: "cli"
      })
      const result = r.frames.find((f: { t: string }) => f.t === "result" || f.t === "reject")
      expect(result.t, JSON.stringify(result)).toBe("result")
      automation = result.value.id
    })
    const run = await op(t, "automation.run", { automation })
    expect(run.ok, JSON.stringify(run)).toBe(true)
    const instance = await introspectWorkflowInstance(testEnv.AUTOMATION_RUN, run.value.id)
    try {
      await fireAlarm(scheduler)
      await instance.waitForStatus("complete")
    } finally {
      await instance[Symbol.asyncDispose]()
    }
    const row = (await read(t, "automation.runs.list", { automation })).value.runs.find((r: { id: string }) => r.id === run.value.id)
    expect(row, JSON.stringify(row)).toMatchObject({ state: "failed", error: { code: "machine.not_found" } })
  })
})
