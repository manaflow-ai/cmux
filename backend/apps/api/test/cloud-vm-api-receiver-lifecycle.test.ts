import type { Principal } from "@cmux/ownership"
import { expect, it } from "vitest"
import { cloudStub } from "./cloud-bind-support.ts"
import { withReceiver } from "./cloud-vm-api-receiver-support.ts"

type Reply = { ok: boolean; value?: { machine: string; generation: string; phase: string }; code?: string }
const lifecycle = (team: string, principal: Principal, machine: string) => {
  const owner = cloudStub(team) as unknown as { vmOp(e: string, p: Principal, op: string, params: unknown): Promise<Reply> }
  return (params: unknown, p = principal) => owner.vmOp(team, p, "cloud.vm.receiver.lifecycle", { machine, ...params as object })
}
const value = (reply: Reply) => {
  expect(reply.ok).toBe(true)
  expect(reply.value?.generation).toMatch(/^[0-9a-f]{64}$/)
  return reply.value!
}

it("persists one receiver incarnation and never revives a stopped attempt", async () => withReceiver(async (f) => {
  const call = lifecycle(f.team, f.principal, f.machine)
  const initial = value(await call({ phase: "read" }))
  expect(initial).toMatchObject({ machine: f.machine, phase: "idle" })
  const request = { phase: "begin", expected: initial.generation, attempt: "a".repeat(32) }
  const first = value(await call(request))
  expect(first.phase).toBe("starting")
  expect(first.generation).not.toBe(initial.generation)
  expect(value(await call(request))).toEqual(first)
  expect(value(await call({ phase: "ready", expected: first.generation })).phase).toBe("ready")
  expect(await call({ phase: "begin", expected: first.generation, attempt: "b".repeat(32) })).toMatchObject({ ok: false, code: "revision.conflict" })
  expect(value(await call(request)).phase).toBe("ready")
  expect(value(await call({ phase: "end", expected: first.generation })).phase).toBe("stopped")
  expect(value(await call(request)).phase).toBe("stopped")
  expect(await call({ phase: "ready", expected: first.generation })).toMatchObject({ ok: false, code: "revision.conflict" })
  const second = value(await call({ phase: "begin", expected: first.generation, attempt: "b".repeat(32) }))
  expect(second.phase).toBe("starting")
  expect(second.generation).not.toBe(first.generation)
  for (const stale of [request, { phase: "ready", expected: first.generation }, { phase: "end", expected: first.generation }]) {
    expect(await call(stale)).toMatchObject({ ok: false, code: "revision.conflict" })
  }
  expect(value(await call({ phase: "read" }))).toEqual(second)
  const transitions = (await f.audit()).filter((r) => r.op === "vm_receiver_lifecycle" && r.changed === true)
  // The private audit reader returns newest entries first.
  expect(transitions.map((r) => r.phase)).toEqual(["begin", "end", "ready", "begin"])
  expect(transitions.every((r) => r.machine === f.machine && r.install === f.principal.install)).toBe(true)
}))

it("admits only the original VM install for its own live machine", async () => withReceiver(async (f) => {
  const call = lifecycle(f.team, f.principal, f.machine)
  const initial = value(await call({ phase: "read" }))
  const begin = { phase: "begin", expected: initial.generation, attempt: "c".repeat(32) }
  for (const principal of [
    { ...f.principal, kind: "session" as const },
    { ...f.principal, install_kind: "mac" },
    { ...f.principal, agent: "agent_00000000000000000001" },
    { ...f.principal, grant_classes: ["execute"] },
    { ...f.principal, bound_machine: "vm_00000000000000000000" },
    { ...f.principal, install: f.client.install, identity: f.client.install },
    { ...f.principal, team: "team_00000000000000000000" },
  ]) {
    expect(await call(begin, principal)).toMatchObject({ ok: false, code: "auth.forbidden" })
  }
  expect(value(await call({ phase: "read" }))).toEqual(initial)
  value(await call(begin))
}))

it("rechecks the original grant on every receiver transition", async () => withReceiver(async (f) => {
  const call = lifecycle(f.team, f.principal, f.machine)
  const initial = value(await call({ phase: "read" }))
  const first = value(await call({ phase: "begin", expected: initial.generation, attempt: "d".repeat(32) }))
  await f.grant("vm", { revoked_at: Date.now() })
  for (const phase of ["read", "ready", "end"]) {
    expect(await call({ phase, ...(phase === "read" ? {} : { expected: first.generation }) })).toMatchObject({ ok: false, code: "auth.forbidden" })
  }
}))

it("rejects malformed or caller-selected authority without changing the incarnation", async () => withReceiver(async (f) => {
  const call = lifecycle(f.team, f.principal, f.machine)
  const initial = value(await call({ phase: "read" }))
  for (const params of [
    { phase: "begin", expected: initial.generation },
    { phase: "begin", expected: "x", attempt: "e".repeat(32) },
    { phase: "begin", expected: initial.generation, attempt: "e".repeat(33) },
    { phase: "ready", expected: initial.generation, attempt: "e".repeat(32) },
    { phase: "read", expected: initial.generation },
    { phase: "read", host: "host_00000000000000000000" },
  ]) {
    expect(await call(params)).toMatchObject({ ok: false, code: "validation.invalid" })
  }
  expect(value(await call({ phase: "read" }))).toEqual(initial)
}))
