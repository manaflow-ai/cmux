import type { SqlStore } from "@cmux/ownership"
import { expect, it } from "vitest"
import { VmReceiverGenerations, type ReceiverTransition, type ReceiverTransitionAudit } from "../src/cloud-vm-receiver-generations.ts"
import { cloudStub } from "./cloud-bind-support.ts"
import { inDO } from "./team-ssh-support.ts"

it("retains the generation across fresh writers and rolls back when audit fails", async () => {
  await inDO(cloudStub("team_00000000000000952101"), async (owner) => {
    const sql = Reflect.get(owner, "sqlStore") as SqlStore
    sql.exec("CREATE TABLE receiver_test_audit (generation TEXT NOT NULL)")
    const machine = "vm_00000000000000952101", scope = "a".repeat(64)
    const audit = (entry: ReceiverTransitionAudit) => { if (entry.changed) sql.exec("INSERT INTO receiver_test_audit VALUES (?)", entry.generation) }
    const apply = (r: ReceiverTransition, record = audit) => new VmReceiverGenerations(sql).apply(machine, scope, r, record)
    const initial = apply({ phase: "read" })
    expect(initial.ok).toBe(true)
    if (!initial.ok) throw new Error("missing initial generation")
    const first = apply({ phase: "begin", expected: initial.value.generation, attempt: "a".repeat(32) })
    expect(first.ok).toBe(true)
    if (!first.ok) throw new Error("missing started generation")
    expect(apply({ phase: "read" })).toEqual(first)
    expect(apply({ phase: "ready", expected: first.value.generation })).toMatchObject({ ok: true, value: { phase: "ready" } })
    expect(() => apply({ phase: "end", expected: first.value.generation }, (entry) => {
      audit(entry)
      throw new Error("audit unavailable")
    })).toThrow("audit unavailable")
    expect(apply({ phase: "read" })).toMatchObject({ ok: true, value: { generation: first.value.generation, phase: "ready" } })
    expect(sql.exec("SELECT * FROM receiver_test_audit")).toHaveLength(2)
    expect(apply({ phase: "end", expected: first.value.generation })).toMatchObject({ ok: true, value: { phase: "stopped" } })
    expect(apply({ phase: "ready", expected: first.value.generation })).toMatchObject({ ok: false, code: "revision.conflict" })
  })
})

it("does not let a late request from an older scope reset a replacement", async () => {
  await inDO(cloudStub("team_00000000000000952103"), async (owner) => {
    const sql = Reflect.get(owner, "sqlStore") as SqlStore
    const machine = "vm_00000000000000952103"
    const call = (scope: string, request: ReceiverTransition) => new VmReceiverGenerations(sql).apply(machine, scope, request, () => {})
    const oldScope = "c".repeat(64), nextScope = "d".repeat(64)
    const oldInitial = call(oldScope, { phase: "read" })
    if (!oldInitial.ok) throw new Error("missing original scope")
    const oldRequest = { phase: "begin" as const, expected: oldInitial.value.generation, attempt: "c".repeat(32) }
    const first = call(oldScope, oldRequest)
    if (!first.ok) throw new Error("missing first incarnation")
    const nextInitial = call(nextScope, { phase: "read" })
    if (!nextInitial.ok) throw new Error("missing next scope")
    const replacement = call(nextScope, { phase: "begin", expected: nextInitial.value.generation, attempt: "d".repeat(32) })
    expect(replacement.ok).toBe(true)
    for (const stale of [oldRequest, { phase: "ready" as const, expected: first.value.generation }, { phase: "end" as const, expected: first.value.generation }]) {
      expect(call(oldScope, stale)).toMatchObject({ ok: false, code: "revision.conflict" })
    }
    expect(call(nextScope, { phase: "read" })).toEqual(replacement)
  })
})

it("refuses corrupt persisted state instead of forgetting a previous attempt", async () => {
  await inDO(cloudStub("team_00000000000000952102"), async (owner) => {
    const sql = Reflect.get(owner, "sqlStore") as SqlStore
    const machine = "vm_00000000000000952102", scope = "b".repeat(64)
    const store = () => new VmReceiverGenerations(sql)
    const initial = store().apply(machine, scope, { phase: "read" }, () => {})
    if (!initial.ok) throw new Error("missing initial generation")
    const begun = store().apply(machine, scope, { phase: "begin", expected: initial.value.generation, attempt: "b".repeat(32) }, () => {})
    expect(begun.ok).toBe(true)
    sql.exec("UPDATE cloud_vm_receiver_generation SET phase = 'invalid' WHERE machine = ?", machine)
    expect(() => store().apply(machine, scope, { phase: "read" }, () => {})).toThrow("receiving incarnation unavailable")
    expect(sql.exec<{ phase: string }>("SELECT phase FROM cloud_vm_receiver_generation WHERE machine = ?", machine)[0]?.phase).toBe("invalid")
  })
})
