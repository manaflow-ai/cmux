import { env } from "cloudflare:workers"
import { MemoryRows, type ReduceContext } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { cloudConfig } from "../src/cloud-driver.ts"
import type { Env } from "../src/env.ts"
import { cloudDomain, publicMachine, TABLE_LEDGER, TABLE_MACHINE, TABLE_SNAPSHOT, type CloudState, type LedgerRow, type MachineRow } from "../src/domains/cloud.ts"
import { publicSnapshot, type SnapshotRow } from "../src/domains/cloud-snapshot.ts"
import { personalTeamIdFor } from "../src/domains/user.ts"

const user = `user_${"a".repeat(20)}`
const team = personalTeamIdFor(user)
const machine = `vm_${"b".repeat(20)}`
const snapshot = `snap_${"c".repeat(20)}`
const size = { cpu: 2, memory_mb: 4096, disk_mb: 16384 }
const config = { environment: "test", allowedTeams: new Set([team]), prefix: "cmuxnp-test-cld-", image: "cmuxnp-test-vmimg-test" }
const apiConfig = { ...config, transport: "vm-api" as const }
const context = (rows: MemoryRows, key = "create"): ReduceContext => ({
  principal: { identity: `user:${user}`, kind: "session", user, team }, now: 1000, tx: key, idempotencyKey: key, rows,
  newId: (kind) => kind === "vm" ? machine : kind === "snap" ? snapshot : `host_${"d".repeat(20)}`
})
const created = () => {
  const rows = new MemoryRows()
  const domain = cloudDomain(config)
  const r = domain.reduce({ ...domain.initial(), team }, "cloud.machine.create", { size }, context(rows))
  if (!r.ok) throw new Error(r.code)
  rows.apply(r.writes ?? [])
  const m = rows.get<MachineRow>(TABLE_MACHINE, machine)!.row
  rows.apply([{ table: TABLE_MACHINE, op: "upsert", key: machine, n: 1, row: { ...m, status: "running", host: `host_${"d".repeat(20)}`, transport: "vm-api" } }])
  return { rows, state: { ...(r.state as CloudState), pending: {} } }
}

describe("Cloud transport ownership", () => {
  it("selects an explicitly configured VM API without a direct provider key", () => {
    const e = { ...(env as Env), CLOUD_DRIVER: undefined, CLOUD_FREESTYLE_API_KEY: undefined, CLOUD_VM_TRANSPORT: "vm-api", CLOUD_VM_API_ORIGIN: "https://vm.test", CLOUD_VM_API_SERVICE_KEY: "test-only-key", CLOUD_VM_API_IMAGE: "cloud-agent", CLOUD_VM_API_IMAGE_REVISION: "v1" }
    expect(cloudConfig(e)).toMatchObject({ transport: "vm-api", prefix: "cmuxnp-test-cld-", image: "cloud-agent" })
    const missing = { ...e, CLOUD_VM_API_SERVICE_KEY: undefined }
    expect(cloudConfig(missing).prefix).toBeNull()
  })

  it("pins new machines and their creation intent to the chosen transport", () => {
    const rows = new MemoryRows()
    const domain = cloudDomain(apiConfig)
    const r = domain.reduce({ ...domain.initial(), team }, "cloud.machine.create", { size }, context(rows))
    expect(r.ok).toBe(true)
    if (!r.ok) return
    rows.apply(r.writes ?? [])
    expect(rows.get(TABLE_MACHINE, machine)?.row).toHaveProperty("transport", "vm-api")
    expect(rows.range(TABLE_LEDGER, { limit: 10 })[0]?.row).toHaveProperty("transport", "vm-api")
    expect(r.value).not.toHaveProperty("machine.transport")
  })

  it.each(["cloud.machine.pause", "cloud.machine.resize", "cloud.machine.delete", "cloud.snapshot.create"])("%s inherits its machine's transport after deployment defaults change", (op) => {
    const { rows, state } = created()
    const r = cloudDomain(config).reduce(state, op, { machine, ...(op.endsWith("resize") ? { size: { memory_mb: 8192 } } : {}) }, context(rows, op))
    expect(r.ok).toBe(true)
    if (!r.ok) return
    const ledger = r.writes?.find((w) => w.table === TABLE_LEDGER && w.op === "upsert" && w.key.endsWith(op))
    expect(ledger).toMatchObject({ row: { transport: "vm-api" } })
    if (op === "cloud.snapshot.create") expect(r.writes?.find((w) => w.table === TABLE_SNAPSHOT)).toMatchObject({ row: { transport: "vm-api" } })
  })

  it("restores and deletes through the snapshot's recorded transport", () => {
    const { rows, state } = created()
    rows.apply([{ table: TABLE_SNAPSHOT, op: "upsert", key: snapshot, n: 2, row: { id: snapshot, machine, name: null, size_mb: 16384, status: "ready", created_at: 1000, revision: "2", provider_name: "cmuxnp-test-cld-snap-cccccccccccccccccccc", creator: user, size, transport: "vm-api" } }])
    const domain = cloudDomain(config)
    const restoreRows = new MemoryRows()
    restoreRows.apply([{ table: TABLE_SNAPSHOT, op: "upsert", key: snapshot, n: 2, row: rows.get(TABLE_SNAPSHOT, snapshot)!.row }])
    const restored = domain.reduce({ ...state, active: 0, pending: {} }, "cloud.snapshot.restore", { snapshot }, context(restoreRows, "restore"))
    expect(restored.ok).toBe(true)
    if (restored.ok) expect(restored.writes?.find((w) => w.table === TABLE_MACHINE)).toMatchObject({ row: { transport: "vm-api" } })
    const deleted = domain.reduce(state, "cloud.snapshot.delete", { snapshot }, context(rows, "delete-snapshot"))
    expect(deleted.ok).toBe(true)
    if (deleted.ok) expect(deleted.writes?.find((w) => w.table === TABLE_LEDGER)).toMatchObject({ row: { transport: "vm-api" } })
  })

  it("retains uncertain capture quota beyond the retry limit until a verified terminal receipt", () => {
    const { rows, state } = created(), domain = cloudDomain(config);
    const admitted = domain.reduce(state, "cloud.snapshot.create", { machine }, context(rows, "capture"));
    if (!admitted.ok) throw new Error(admitted.code);
    rows.apply(admitted.writes ?? []);
    let current = admitted.state as CloudState;
    const key = rows.range<LedgerRow>(TABLE_LEDGER, { limit: 10 }).find((r) => r.row.op === "snapshot")?.key;
    if (!key) throw new Error("capture ledger missing");
    for (let attempt = 0; attempt < 7; attempt++) {
      const result = domain.reduce(current, "cloud.driver_result", { key, ok: false, final: true,
        error: { code: "cloud.provider.unavailable", message: "no authoritative answer" } }, context(rows, `result-${attempt}`));
      if (!result.ok) throw new Error(result.code);
      rows.apply(result.writes ?? []); current = result.state as CloudState;
      expect(current.saved).toBe(1);
      expect(current.pending[key]).toBeDefined();
      expect(rows.get<SnapshotRow>(TABLE_SNAPSHOT, snapshot)?.row.status).toBe("creating");
    }
    const closed = domain.reduce(current, "cloud.driver_result", { key, ok: false, final: true, snapshot_outcome: "deleted" }, context(rows, "verified-deleted"));
    if (!closed.ok) throw new Error(closed.code);
    rows.apply(closed.writes ?? []);
    expect((closed.state as CloudState).saved).toBe(0);
    expect((closed.state as CloudState).pending[key]).toBeUndefined();
    expect(rows.get<SnapshotRow>(TABLE_SNAPSHOT, snapshot)?.row.status).toBe("failed");
  });

  it("keeps private transport fields out of public machine and snapshot projections", () => {
    const { rows } = created()
    expect(publicMachine(rows.get<MachineRow>(TABLE_MACHINE, machine)!.row)).not.toHaveProperty("transport")
    const row: SnapshotRow = { id: snapshot, machine, name: null, size_mb: 16384, status: "ready", created_at: 1000, revision: "2", provider_name: "private", creator: user, size, transport: "vm-api" }
    expect(publicSnapshot(row)).not.toHaveProperty("transport")
  })
})
