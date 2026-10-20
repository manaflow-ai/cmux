import { expect, it } from "vitest"
import { withReceiver } from "./cloud-vm-api-receiver-support.ts"

const errorCode = (reply: any) => reply.json.error?.code ?? reply.json.code

it("executes receiver lifecycle through the catalog using the VM's challenge-issued credential", async () => withReceiver(async (f) => {
  const read = await f.lifecycleHttp({ phase: "read" })
  expect(read.status).toBe(200)
  expect(read.json).toMatchObject({ ok: true, op: "cloud.vm.receiver.lifecycle", replayed: false, idempotency_key: "", value: { machine: f.machine, phase: "idle" } })
  expect(Object.keys(read.json.value).sort()).toEqual(["generation", "machine", "phase"])
  const begin = { phase: "begin", expected: read.json.value.generation, attempt: "a".repeat(32) }
  const first = await f.lifecycleHttp(begin)
  expect(first.json).toMatchObject({ ok: true, value: { phase: "starting" } })
  const retry = await f.lifecycleHttp(begin)
  expect(retry.json.value).toEqual(first.json.value)
  expect(retry.json.transaction).not.toBe(first.json.transaction)
  expect(retry.json.replayed).toBe(false)
  expect((await f.lifecycleHttp({ phase: "ready", expected: first.json.value.generation })).json.value.phase).toBe("ready")
  expect((await f.lifecycleHttp({ phase: "end", expected: first.json.value.generation })).json.value.phase).toBe("stopped")
  expect((await f.lifecycleHttp(begin)).json.value.phase).toBe("stopped")
  expect(errorCode(await f.lifecycleHttp({ phase: "ready", expected: first.json.value.generation }))).toBe("revision.conflict")
}))

it("retains machine scoping and fresh authority checks with a cached VM bearer", async () => withReceiver(async (f) => {
  const initial = await f.lifecycleHttp({ phase: "read" })
  expect(initial.json.ok).toBe(true)
  expect(errorCode(await f.lifecycleHttp({ phase: "read", machine: "vm_00000000000000000000" }))).toBe("auth.forbidden")
  expect(errorCode(await f.lifecycleHttp({ phase: "read", scope: "caller-selected" }))).toBe("validation.invalid")
  const keyed = await f.lifecycleHttp({ phase: "read" }, { idempotency_key: "must-not-replay" })
  expect(keyed.status).toBe(400)
  expect(errorCode(keyed)).toBe("validation.invalid")
  expect((await f.lifecycleHttp({ phase: "read" })).json.value).toEqual(initial.json.value)
  await f.grant("vm", { revoked_at: Date.now() })
  expect(errorCode(await f.lifecycleHttp({ phase: "read" }))).toBe("auth.forbidden")
}))

it("keeps a person's session and client grant outside the VM lifecycle boundary", async () => withReceiver(async (f) => {
  const initial = await f.lifecycleHttp({ phase: "read" })
  expect(initial.json.ok).toBe(true)
  for (const caller of ["session", "client"] as const) {
    expect(errorCode(await f.lifecycleHttp({ phase: "read" }, { caller }))).toBe("auth.forbidden")
  }
  expect((await f.lifecycleHttp({ phase: "read" })).json.value).toEqual(initial.json.value)
}))
