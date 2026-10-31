import { env } from "cloudflare:workers"
import { MemoryRows, type ReduceContext } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { cloudConfig, GuardedCloudDriver } from "../src/cloud-driver.ts"
import type { Env } from "../src/env.ts"
import { cloudDomain, publicMachine, TABLE_LEDGER, TABLE_MACHINE, TABLE_SNAPSHOT, type CloudState, type LedgerRow, type MachineRow } from "../src/domains/cloud.ts"
import { emptyFenceSettles, publicSnapshot, type SnapshotRow } from "../src/domains/cloud-snapshot.ts"
import { VmApiCloudDriver } from "../src/cloud-vm-api.ts"
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

  it("keeps quota through pending snapshot deletion and ignores a late capture result", () => {
    const { rows, state } = created(), domain = cloudDomain(config);
    const capture = domain.reduce(state, "cloud.snapshot.create", { machine }, context(rows, "capture-cancel"));
    if (!capture.ok) throw new Error(capture.code);
    rows.apply(capture.writes ?? []);
    const original = rows.range<LedgerRow>(TABLE_LEDGER, { limit: 20 }).find((r) => r.row.op === "snapshot")!;
    const deleting = domain.reduce(capture.state as CloudState, "cloud.snapshot.delete", { snapshot }, context(rows, "delete-capture"));
    if (!deleting.ok) throw new Error(deleting.code);
    rows.apply(deleting.writes ?? []);
    let current = deleting.state as CloudState;
    expect(current.saved).toBe(1);
    expect(current.pending[original.key]).toBeUndefined();
    expect(rows.get<LedgerRow>(TABLE_LEDGER, original.key)?.row.state).toBe("cancelled");
    const late = domain.reduce(current, "cloud.driver_result", { key: original.key, ok: true, provider_id: "late-capture" }, context(rows, "late-success"));
    if (!late.ok) throw new Error(late.code);
    rows.apply(late.writes ?? []); current = late.state as CloudState;
    expect(rows.get<SnapshotRow>(TABLE_SNAPSHOT, snapshot)?.row.status).toBe("deleting");
    const deletion = rows.range<LedgerRow>(TABLE_LEDGER, { limit: 20 }).find((r) => r.row.op === "snapshot_delete")!;
    for (let i = 0; i < 7; i++) {
      const pending = domain.reduce(current, "cloud.driver_result", { key: deletion.key, ok: false, final: true }, context(rows, `delete-result-${i}`));
      if (!pending.ok) throw new Error(pending.code);
      rows.apply(pending.writes ?? []); current = pending.state as CloudState;
      expect(current.saved).toBe(1);
    }
    const closed = domain.reduce(current, "cloud.driver_result", { key: deletion.key, ok: true }, context(rows, "cleanup-complete"));
    if (!closed.ok) throw new Error(closed.code);
    rows.apply(closed.writes ?? []);
    expect((closed.state as CloudState).saved).toBe(0);
    expect(rows.get(TABLE_SNAPSHOT, snapshot)).toBeUndefined();
  });

  it("accounts for cleanup of an older failed snapshot until the outcome is verified", () => {
    const { rows, state } = created(), domain = cloudDomain(config);
    rows.apply([{ table: TABLE_SNAPSHOT, op: "upsert", key: snapshot, n: 2, row: { id: snapshot, machine, name: null, size_mb: 16384,
      status: "failed", created_at: 1000, revision: "2", provider_name: "cmuxnp-test-cld-snap-cccccccccccccccccccc", creator: user, size, transport: "vm-api" } }]);
    const deleting = domain.reduce({ ...state, saved: 0 }, "cloud.snapshot.delete", { snapshot }, context(rows, "old-failure-delete"));
    if (!deleting.ok) throw new Error(deleting.code);
    expect((deleting.state as CloudState).saved).toBe(1);
    rows.apply(deleting.writes ?? []);
    const deletion = rows.range<LedgerRow>(TABLE_LEDGER, { limit: 20 }).find((r) => r.row.op === "snapshot_delete")!;
    const done = domain.reduce(deleting.state as CloudState, "cloud.driver_result", { key: deletion.key, ok: true }, context(rows, "old-failure-cleaned"));
    if (!done.ok) throw new Error(done.code);
    expect((done.state as CloudState).saved).toBe(0);
  });

  it("releases the saved slot when a capture ends before any send was admitted", () => {
    const { rows, state } = created(), domain = cloudDomain(config);
    const admitted = domain.reduce(state, "cloud.snapshot.create", { machine }, context(rows, "capture"));
    if (!admitted.ok) throw new Error(admitted.code);
    rows.apply(admitted.writes ?? []);
    expect((admitted.state as CloudState).saved).toBe(1);
    const key = rows.range<LedgerRow>(TABLE_LEDGER, { limit: 10 }).find((r) => r.row.op === "snapshot")?.key;
    if (!key) throw new Error("capture ledger missing");
    const closed = domain.reduce(admitted.state as CloudState, "cloud.driver_result", { key, ok: false, final: true, snapshot_outcome: "absent",
      error: { code: "cloud.provider.vm_missing", message: "snapshot: no VM under the recorded name" } }, context(rows, "absent"));
    if (!closed.ok) throw new Error(closed.code);
    rows.apply(closed.writes ?? []);
    expect((closed.state as CloudState).saved).toBe(0);
    expect((closed.state as CloudState).pending[key]).toBeUndefined();
    expect(rows.get<SnapshotRow>(TABLE_SNAPSHOT, snapshot)?.row.status).toBe("failed");
  });

  it("finishes deleting a legacy failed capture whose key the VM service never admitted", async () => {
    const { rows, state } = created(), domain = cloudDomain(apiConfig);
    const slug = "cmuxnp-test-cld-snap-cccccccccccccccccccc";
    rows.apply([{ table: TABLE_SNAPSHOT, op: "upsert", key: snapshot, n: 2, row: { id: snapshot, machine, name: null, size_mb: 16384,
      status: "failed", created_at: 1000, revision: "2", provider_name: slug, creator: user, size, transport: "vm-api" } }]);
    const deleting = domain.reduce({ ...state, saved: 0 }, "cloud.snapshot.delete", { snapshot }, context(rows, "legacy-failed-delete"));
    if (!deleting.ok) throw new Error(deleting.code);
    rows.apply(deleting.writes ?? []);
    const deletion = rows.range<LedgerRow>(TABLE_LEDGER, { limit: 20 }).find((r) => r.row.op === "snapshot_delete")!.row;
    // The legacy row predates capture_protocol; by-key is 404, the fence comes back empty and nothing is owned.
    const fetchFn: typeof fetch = async (input, init) => {
      const path = new URL(new Request(input, init).url).pathname;
      if (path === "/v1/snapshot-creations/by-key/cancel") return Response.json({ state: "fenced", id: null });
      if (path === "/v1/snapshots") return Response.json({ items: [], nextCursor: null });
      return new Response(null, { status: 404 });
    };
    const driver = new GuardedCloudDriver(new VmApiCloudDriver({ origin: "https://vm.test", key: "test-only-key", image: { id: "cloud-agent", revision: "v1" } }, "stack-team", team, fetchFn), "cmuxnp-test-cld-");
    await expect(driver.removeSnapshot(slug, { team, machine }, emptyFenceSettles(deletion))).resolves.toBeUndefined();
    const done = domain.reduce(deleting.state as CloudState, "cloud.driver_result", { key: deletion.key, ok: true }, context(rows, "legacy-failed-cleaned"));
    if (!done.ok) throw new Error(done.code);
    rows.apply(done.writes ?? []);
    expect((done.state as CloudState).saved).toBe(0);
    expect(rows.get(TABLE_SNAPSHOT, snapshot)).toBeUndefined();
  });

  // SW-00 / cmux-platform#187: listing a fleet must recover after one
  // transient VM API failure, while pages 2+ share the report's first snapshot.
  it("retries a failed VM API report and refreshes the next report without mixing pages", async () => {
    let calls = 0
    const listed = [
      { id: `vm_${"a".repeat(26)}`, labels: { role: "cloud", cmux_next_team: team, "cmux/name": "machine-a" } },
    ]
    const fetchFn: typeof fetch = async (input, init) => {
      const url = new URL(new Request(input, init).url)
      expect(url.pathname).toBe("/v1/vms")
      expect(url.searchParams.getAll("label")).toContain(`cmux_next_team=${team}`)
      calls += 1
      if (calls === 1) return Response.json({ error: "temporarily unavailable" }, { status: 503 })
      return Response.json({ items: listed, nextCursor: null })
    }
    const driver = new VmApiCloudDriver(
      { origin: "https://vm.test", key: "test-only-key", image: { id: "cloud-agent", revision: "v1" } },
      "stack-team", team, fetchFn,
    )
    const selector = `cmux_next_team:${team}`

    await expect(driver.list(selector, 0)).rejects.toMatchObject({ code: "cloud.provider.unavailable", final: false })
    expect(calls).toBe(1)
    const recovered = await driver.list(selector, 0)
    expect(recovered).toMatchObject({ total: 1, vms: [{ id: listed[0]!.id, name: "machine-a" }] })
    expect(calls).toBe(2)

    // The next page is part of the same report and should never make another request.
    expect(await driver.list(selector, 100)).toMatchObject({ total: 1, vms: [] })
    expect(calls).toBe(2)

    // The next offset-zero scan is a new report. A forever-cached success lies about new VMs.
    listed.push({ id: `vm_${"b".repeat(26)}`, labels: { role: "cloud", cmux_next_team: team, "cmux/name": "machine-b" } })
    const updated = await driver.list(selector, 0)
    expect(updated).toMatchObject({ total: 2, vms: [{ name: "machine-a" }, { name: "machine-b" }] })
    expect(calls).toBe(3)
  })

  it("keeps private transport fields out of public machine and snapshot projections", () => {
    const { rows } = created()
    expect(publicMachine(rows.get<MachineRow>(TABLE_MACHINE, machine)!.row)).not.toHaveProperty("transport")
    const row: SnapshotRow = { id: snapshot, machine, name: null, size_mb: 16384, status: "ready", created_at: 1000, revision: "2", provider_name: "private", creator: user, size, transport: "vm-api", capture_protocol: 1, saved_reserved: true }
    expect(publicSnapshot(row)).not.toHaveProperty("transport")
    expect(publicSnapshot(row)).not.toHaveProperty("capture_protocol")
    expect(publicSnapshot(row)).not.toHaveProperty("saved_reserved")
  })
})
