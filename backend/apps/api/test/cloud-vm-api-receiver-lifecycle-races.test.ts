import type { RowRange, RowReader, SqlStore } from "@cmux/ownership"
import { expect, it } from "vitest"
import { cloudVmReceiverLifecycle } from "../src/cloud-vm-receiver-lifecycle.ts"
import { TABLE_MACHINE, type MachineRow } from "../src/domains/cloud.ts"
import { cloudStub } from "./cloud-bind-support.ts"
import { inDO } from "./team-ssh-support.ts"
import { withReceiver } from "./cloud-vm-api-receiver-support.ts"

it.each(["rebind", "timeout"])("fences a late original-grant read after %s", async (mode) => withReceiver(async (f) => {
  await inDO(cloudStub(f.team), async (owner) => {
    const read = () => owner.vmOp(f.team, f.principal, "cloud.vm.receiver.lifecycle", { machine: f.machine, phase: "read" })
    const initial = await read()
    expect(initial.ok).toBe(true)
    const rows = owner.bind(f.team).rows as RowReader
    let returned = false
    const current: RowReader = {
      get<T>(table: string, key: string) {
        const stored = rows.get<T>(table, key)
        if (!stored || !returned || mode !== "rebind" || table !== TABLE_MACHINE || key !== f.machine) return stored
        const machine = stored.row as unknown as MachineRow
        return { ...stored, row: { ...machine, epoch: Number(machine.epoch) + 1 } as unknown as T }
      },
      range<T>(table: string, range: RowRange) { return rows.range<T>(table, range) }
    }
    const now = Date.now()
    const result = await cloudVmReceiverLifecycle({ team: f.team, rows: current,
      now: () => now + (returned && mode === "timeout" ? 15_000 : 0),
      sql: () => Reflect.get(owner, "sqlStore") as SqlStore,
      own: async (user, install, grant, machine) => {
        const original = await owner.env.USER_DO.get(owner.env.USER_DO.idFromName(user)).vmNetworkIdentity(user, install, grant, f.team, machine)
        returned = true
        return original
      }, audit: () => {}
    }, f.principal, { machine: f.machine, phase: "begin", expected: initial.value.generation, attempt: "e".repeat(32) })
    expect(returned).toBe(true)
    expect(result).toMatchObject({ ok: false, code: mode === "rebind" ? "auth.forbidden" : "owner.unreachable" })
    expect(await read()).toEqual(initial)
  })
}))

it.each(["pausing", "paused"])("retires an original receiver while its machine is %s", async (status) => withReceiver(async (f) => {
  await inDO(cloudStub(f.team), async (owner) => {
    const op = (phase: string, expected?: string, attempt?: string) => owner.vmOp(f.team, f.principal, "cloud.vm.receiver.lifecycle",
      { machine: f.machine, phase, ...(expected ? { expected } : {}), ...(attempt ? { attempt } : {}) })
    const initial = await op("read")
    expect(initial.ok).toBe(true)
    const first = await op("begin", initial.value.generation, "f".repeat(32))
    expect(first.ok).toBe(true)
    expect((await op("ready", first.value.generation)).ok).toBe(true)
    const rows = owner.bind(f.team).rows as RowReader
    const parked: RowReader = {
      get<T>(table: string, key: string) {
        const stored = rows.get<T>(table, key)
        if (!stored || table !== TABLE_MACHINE || key !== f.machine) return stored
        return { ...stored, row: { ...stored.row as object, status } as T }
      },
      range<T>(table: string, range: RowRange) { return rows.range<T>(table, range) }
    }
    const call = (phase: string) => cloudVmReceiverLifecycle({ team: f.team, rows: parked, now: () => Date.now(),
      sql: () => Reflect.get(owner, "sqlStore") as SqlStore,
      own: (user, install, grant, machine) => owner.env.USER_DO.get(owner.env.USER_DO.idFromName(user)).vmNetworkIdentity(user, install, grant, f.team, machine),
      audit: () => {}
    }, f.principal, { machine: f.machine, phase, expected: first.value.generation })
    expect(await call("ready")).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(await call("end")).toMatchObject({ ok: true, value: { generation: first.value.generation, phase: "stopped" } })
    expect(await op("read")).toMatchObject({ ok: true, value: { generation: first.value.generation, phase: "stopped" } })
  })
}))
