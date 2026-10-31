import { runInDurableObject } from "cloudflare:test"
import { describe, expect, it } from "vitest"
import { fireAlarm } from "./setup/alarm.ts"
import { env } from "cloudflare:workers"
import { registerVmInstall } from "../src/cloud-vm.ts"
import { REVOKE_RECEIPT_RETENTION_MS } from "../src/cloud-vm-revoke.ts"
import { bindFile, cloudStub, DAEMON, post, SIZE, signedInWithInstall, vmKey, WG_KEY } from "./cloud-bind-support.ts"

/**
 * Every terminal machine state ends the VM install through one durable path (cloud-vm-revoke.ts):
 * deleting (accepted delete), failed, removed (finished delete or a cleared ledger row's machine),
 * a refused bind, a re-bind. A failed revoke stays queued and the alarm retries it.
 */

const inDo = runInDurableObject as unknown as <T>(s: unknown, f: (i: any) => Promise<T>) => Promise<T>
const read = (token: string, op: string, params: unknown) => post("/v1/read", token, { op, params })

const bound = async (sub: string) => {
  const a = await signedInWithInstall(sub, "mac")
  const created = await post("/v1/ops", a.session, { op: "cloud.machine.create", params: { size: SIZE }, idempotency_key: crypto.randomUUID(), origin: "user" })
  const machine = created.body.value.machine.id as string
  const stub = cloudStub(a.team)
  const { json } = await bindFile(stub, machine)
  const key = await vmKey()
  const b = await post("/v1/cloud/bind", undefined, { team: a.team, machine, bind_token: json.bind_token, wg_public_key: WG_KEY, daemon: DAEMON, install_public_jwk: key.jwk })
  const install = b.body.value.install.id as string
  const revoked = async () => (await read(a.session, "install.list", {})).body.value.installs.find((i: any) => i.id === install).revoked_at !== null
  return { a, machine, stub, install, revoked }
}

describe("VM install revocation on every terminal state", { timeout: 60_000 }, () => {
  it("failed: a machine the commit leaves failed loses its VM install", async () => {
    const s = await bound("cloud-bind-3")
    expect(await s.revoked()).toBe(false)
    await inDo(s.stub, async (i) => {
      i.vmRevokes.reconcile(s.machine, { ...i.boundEngine.rows.get("machine", s.machine).row, status: "failed" }, Date.now())
      await i.drainRevokes(Date.now())
    })
    expect(await s.revoked()).toBe(true)
  })

  it("removed: a cleared ledger row's machine (row gone) loses its VM install", async () => {
    const s = await bound("cloud-bind-4")
    await inDo(s.stub, async (i) => {
      i.afterOp({ identity: "system:cloud", kind: "system" }, "cloud.abandoned_clear", [{ t: "result", value: { cleared: true, audit: { machine: s.machine } } }])
    })
    // The machine row still exists and runs: a clear of an unrelated ledger row changes nothing.
    expect(await s.revoked()).toBe(false)
    await inDo(s.stub, async (i) => {
      i.vmRevokes.reconcile(s.machine, undefined, Date.now())
      await i.drainRevokes(Date.now())
    })
    expect(await s.revoked()).toBe(true)
  })

  it("a failed revoke stays queued and the alarm retries it", async () => {
    const s = await bound("cloud-bind-5")
    await s.stub.fakeControl({ fail_revokes: 1 } as never)
    expect((await post("/v1/ops", s.a.session, { op: "cloud.machine.delete", params: { machine: s.machine }, idempotency_key: crypto.randomUUID(), origin: "user" })).body.ok).toBe(true)
    expect(await s.revoked()).toBe(false)
    expect(((await s.stub.fakeControl({})) as any).vm_revokes).toEqual([{ install: s.install, why: "deleting", attempts: 1 }])
    await s.stub.fakeControl({ advance_ms: 10 * 60_000 } as never)
    await fireAlarm(s.stub)
    expect(await s.revoked()).toBe(true)
    expect(((await s.stub.fakeControl({})) as any).vm_revokes).toEqual([])
  })

  it("a revoked install is not queued again by a later commit (review P3)", async () => {
    const s = await bound("cloud-bind-6")
    expect((await post("/v1/ops", s.a.session, { op: "cloud.machine.delete", params: { machine: s.machine }, idempotency_key: crypto.randomUUID(), origin: "user" })).body.ok).toBe(true)
    expect(await s.revoked()).toBe(true)
    const again = await inDo(s.stub, async (i) => {
      i.vmRevokes.reconcile(s.machine, { ...(i.boundEngine.rows.get("machine", s.machine)?.row ?? { creator: "x" }), status: "failed", vm_install: s.install }, Date.now())
      return i.vmRevokes.pending()
    })
    expect(again).toEqual([])
  })

  it("prunes completed receipts after the retention window in bounded alarm work", async () => {
    const s = await bound("cloud-bind-1")
    const completedAt = Date.now() + s.a.team.length
    const requeued = await inDo(s.stub, async (i) => {
      i.vmRevokes.queue("receipt-prune-test", s.a.user, "test", completedAt)
      await i.vmRevokes.drain(completedAt, async () => true)
      // The receipt remains during the audit window, so idempotent queueing is a no-op.
      i.vmRevokes.queue("receipt-prune-test", s.a.user, "test", completedAt + 1)
      expect(i.vmRevokes.pending()).toEqual([])
      await i.vmRevokes.drain(completedAt + REVOKE_RECEIPT_RETENTION_MS + 1, async () => true)
      // Once pruned, a later occurrence can be queued again without an
      // unbounded completed-row table.
      i.vmRevokes.queue("receipt-prune-test", s.a.user, "test-again", completedAt + REVOKE_RECEIPT_RETENTION_MS + 2)
      return i.vmRevokes.pending()
    })
    expect(requeued).toEqual([{ install: "receipt-prune-test", why: "test-again", attempts: 0 }])
  })

  it("prunes expired rows in batches without touching pending retries", async () => {
    const s = await bound("cloud-route-5")
    const remaining = await inDo(s.stub, async (i) => {
      const at = Date.now() + i.skewMs
      for (let n = 0; n < 105; n++) i.vmRevokes.queue("receipt-batch-" + n, s.a.user, "test", at)
      for (let n = 0; n < 6; n++) await i.vmRevokes.drain(at, async () => true)
      const sql = Reflect.get(i, "sqlStore") as { exec: <T>(query: string, ...params: Array<unknown>) => Array<T> }
      const count = () => sql.exec<{ total: number; done: number }>("SELECT count(*) AS total, sum(done) AS done FROM cloud_vm_revoke")[0]
      expect(count()).toEqual({ total: 105, done: 105 })
      expect(i.vmRevokes.dueAt()).toBe(at + REVOKE_RECEIPT_RETENTION_MS)
      i.vmRevokes.queue("receipt-pending", s.a.user, "pending", at)
      await i.vmRevokes.drain(at, async ({ install }: { install: string }) => install !== "receipt-pending")
      expect(count()).toEqual({ total: 106, done: 105 })
      expect(i.vmRevokes.pending()).toEqual([{ install: "receipt-pending", why: "pending", attempts: 1 }])
      expect(i.vmRevokes.dueAt()).toBe(at + 5_000)
      await i.vmRevokes.drain(at + REVOKE_RECEIPT_RETENTION_MS + 1, async ({ install }: { install: string }) => install !== "receipt-pending")
      expect(count()).toEqual({ total: 6, done: 5 })
      await i.vmRevokes.drain(at + REVOKE_RECEIPT_RETENTION_MS + 2, async ({ install }: { install: string }) => install !== "receipt-pending")
      expect(count()).toEqual({ total: 1, done: 0 })
      return i.vmRevokes.pending()
    })
    expect(remaining).toEqual([{ install: "receipt-pending", why: "pending", attempts: 2 }])
  })

  it("crash window: an install registered for a bind that never committed is revoked by the alarm after a grace; a bound one is kept", async () => {
    const a = await signedInWithInstall("cloud-bind-2", "mac")
    const created = await post("/v1/ops", a.session, { op: "cloud.machine.create", params: { size: SIZE }, idempotency_key: crypto.randomUUID(), origin: "user" })
    const machine = created.body.value.machine.id as string
    const stub = cloudStub(a.team)
    const key = await vmKey()
    // The object recorded the registration and UserDO made the install, then the object died before the bind commit.
    const orphan = await inDo(stub, async (i) => {
      const reg = { creator: a.user, team: a.team, machine, epoch: 1, jwk: key.jwk }
      i.vmRevokes.beginRegister(reg, Date.now() + i.skewMs)
      const r = await registerVmInstall(env as never, reg)
      return r.ok ? r.id : ""
    })
    const isRevoked = async (id: string) => (await read(a.session, "install.list", {})).body.value.installs.find((x: any) => x.id === id).revoked_at !== null
    await fireAlarm(stub)
    expect(await isRevoked(orphan)).toBe(false)
    await stub.fakeControl({ advance_ms: 11 * 60_000 } as never)
    await fireAlarm(stub)
    expect(await isRevoked(orphan)).toBe(true)
    // A completed bind leaves nothing for the pass to revoke.
    const s = await bound("cloud-bind-1")
    await s.stub.fakeControl({ advance_ms: 11 * 60_000 } as never)
    await fireAlarm(s.stub)
    expect(await s.revoked()).toBe(false)
  })

  it("a registration that UserDO refuses settles once (no alarm loop) and revokes nothing (review P2)", async () => {
    const s = await bound("cloud-bind-4")
    const a2 = await post("/v1/ops", s.a.session, { op: "cloud.machine.create", params: { size: SIZE }, idempotency_key: crypto.randomUUID(), origin: "user" })
    const machine2 = a2.body.value.machine.id as string
    // The second machine's bind reuses the first VM's public key: UserDO refuses ("already registered").
    const jwk = (await read(s.a.session, "install.list", {})).body.value.installs.find((x: any) => x.id === s.install).public_jwk
    const due = await inDo(s.stub, async (i) => {
      i.vmRevokes.beginRegister({ creator: s.a.user, team: s.a.team, machine: machine2, epoch: 1, jwk }, Date.now() + i.skewMs)
      return i.vmRevokes.registerDueAt()
    })
    expect(due).not.toBeNull()
    await s.stub.fakeControl({ advance_ms: 11 * 60_000 } as never)
    await fireAlarm(s.stub)
    expect(await inDo(s.stub, async (i) => i.vmRevokes.registerDueAt())).toBeNull()
    expect(await s.revoked()).toBe(false)
  })
})
