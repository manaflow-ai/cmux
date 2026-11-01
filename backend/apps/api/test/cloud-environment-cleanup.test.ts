import { env } from "cloudflare:workers"
import { describe, expect, it } from "vitest"
import { CloudDO } from "../src/cloud-do.ts"
import { GuardedCloudDriver } from "../src/cloud-driver.ts"
import { FakeCloudDriver } from "../src/cloud-driver-fake.ts"
import { DriverError } from "../src/team-vm-driver.ts"
import type { Env } from "../src/env.ts"
import { TABLE_LEDGER, type LedgerRow } from "../src/domains/cloud.ts"
import { frame, person, reply } from "./cloud-bind-support.ts"
import { inDO } from "./team-ssh-support.ts"

/** Only the SQLite fake provider: no provider HTTP, external database, or VM is used. */
describe("environment cleanup survives build completion", () => {
  it.each(["builder", "warm", "missing", "repeated", "setup-failed", "both", "mismatch"] as const)("retries %s cleanup from the persisted ledger after a restart", async (kind) => {
    const x = person()
    await inDO(x.stub, async (_instance, state) => {
      let deletes = 0
      const failures = new Map<string, number>()
      class Owner extends CloudDO {
        protected override async driverFor() {
          const sql = this.sqlStore
          class Provider extends FakeCloudDriver {
            override async delete(id: string) {
              const vm = sql.exec<{ snapshot: string | null }>("SELECT snapshot FROM cloud_fake_vm WHERE id = ?", id)[0]
              const target = kind === "both" || (kind === "warm" ? vm?.snapshot !== null : vm?.snapshot === null)
              if (target) {
                deletes++
                // Fail both the build's best-effort delete and its first durable
                // cleanup attempt in this same alarm; recovery happens after restart.
                const remaining = failures.get(id) ?? ((kind === "repeated" || kind === "both") && vm?.snapshot === null ? 8 : 2)
                failures.set(id, remaining - 1)
                if (remaining > 0) throw new DriverError("cloud.provider.unavailable", "transient delete failure", false)
              }
              return super.delete(id)
            }
          }
          return new GuardedCloudDriver(new Provider(sql), "cmuxnp-test-cld-")
        }
        pendingCleanup() {
          return this.boundEngine!.rows.range<LedgerRow>(TABLE_LEDGER, { limit: 100 }).map((r) => r.row).filter((r) => r.state === "pending" && r.op !== "env_build")
        }
        pendingBuilds() { return Object.keys(this.boundEngine!.currentState.pending).length }
      }
      let owner = new Owner(state, env as Env)
      const wake = async () => { await state.storage.deleteAlarm(); await owner.alarmIdle; await owner.alarm() }
      const submit = async (op: string, params: unknown) => {
        const r = reply(await owner.submit(x.team, x.p, frame(op, params)))
        expect(r.t, JSON.stringify(r)).toBe("result")
        return r.value
      }
      const created = await submit("cloud.environment.set", { name: "cleanup", setup_script: "true" })
      if (kind === "setup-failed") await owner.fakeControl({ exec_build_exit: 3 })
      await submit("cloud.environment.build", { environment: created.environment.id })
      await wake()
      const result = await owner.readOp(x.team, x.p, "cloud.environment.list", {})
      expect(result).toMatchObject({ ok: true, value: { environments: [{ status: kind === "setup-failed" ? "failed" : "ready" }] } })
      expect((await owner.fakeControl({})).vms).toHaveLength(kind === "both" ? 2 : 1)
      // On base the build's last pending entry is dropped even though its VM is still running.
      expect(owner.pendingCleanup().length).toBeGreaterThan(0)
      const pending = owner.pendingCleanup()
      expect(pending.every((r) => r.attempts === 1)).toBe(true)
      const survivor = (await owner.fakeControl({})).vms[0]!
      expect(survivor.idle).toBe(-1)
      expect(pending.some((r) => r.provider_name === survivor.name && r.transport === "direct")).toBe(true)
      expect(await state.storage.getAlarm()).not.toBeNull()
      // Reconstruct the owner: retry state must be in SQLite, not an in-memory callback.
      owner = new Owner(state, env as Env)
      await owner.readOp(x.team, x.p, "cloud.environment.list", {})
      expect(owner.pendingCleanup()).toEqual(pending)
      if (kind === "missing") await owner.fakeControl({ delete_vm: survivor.name })
      if (kind === "mismatch") {
        const original = state.storage.sql.exec<{ tag: string }>("SELECT tag FROM cloud_fake_vm WHERE name = ?", survivor.name).toArray()[0]!.tag
        state.storage.sql.exec("UPDATE cloud_fake_vm SET tag = ? WHERE name = ?", JSON.stringify({ cmux_next_team: "another-team", cmux_next_machine: "another-machine" }), survivor.name)
        await owner.fakeControl({ advance_ms: 400_000 })
        await wake()
        expect((await owner.fakeControl({})).vms).toHaveLength(1)
        expect(owner.pendingCleanup()).toMatchObject([{ error: { code: "cloud.provider.name_conflict" } }])
        state.storage.sql.exec("UPDATE cloud_fake_vm SET tag = ? WHERE name = ?", original, survivor.name)
      }
      for (let attempt = 0; attempt < ((kind === "repeated" || kind === "both") ? 7 : 1); attempt++) {
        await owner.fakeControl({ advance_ms: 400_000 })
        await owner.alarm()
        if ((kind === "repeated" || kind === "both") && attempt < 6) {
          expect(owner.pendingCleanup().length).toBeGreaterThan(0)
          expect((await owner.fakeControl({})).vms).toHaveLength(1) // Warm cleanup is not starved.
          const before = deletes
          await wake()
          expect(deletes).toBe(before) // Backoff: an early alarm cannot spend attempts.
        }
      }
      expect((await owner.fakeControl({})).vms).toEqual([])
      expect(owner.pendingCleanup()).toEqual([])
      expect(owner.pendingBuilds()).toBe(0)
      if (kind === "missing") expect(deletes).toBe(2) // Missing VM is confirmed without another delete.
      await state.storage.deleteAlarm()
    })
  })
})
