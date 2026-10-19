import { env } from "cloudflare:workers"
import type { Vm } from "@cmux/vm"
import { expect, it, vi } from "vitest"
import { CloudDO } from "../src/cloud-do.ts"
import type { Env } from "../src/env.ts"
import type { SubmitResult } from "../src/owner-do.ts"
import { mirroredTeam, teamStub } from "./team-stack-support.ts"
import { personalTeamIdFor } from "../src/domains/user.ts"
import type { PersonalTenantMarker } from "../src/team-vm-api-personal-store.ts"
import { inDO } from "./team-ssh-support.ts"
import { DAEMON, vmKey, WG_KEY } from "./cloud-bind-support.ts"

/** Real Cloud owner, reducers, ledger and bind registration; only the HTTP VM service is fake. */
it.each(["shared", "personal", "lost-capture", "cancel-capture"] as const)("runs a mixed %s Cloud lifecycle through recorded transports after deployment defaults change", async (kind) => {
  const original = await mirroredTeam("VM API owner lifecycle")
  const t = { ...original, team: kind === "personal" ? personalTeamIdFor(original.user) : original.team, stackTeam: kind === "personal" ? "e6fb9d09-d951-4a65-9d21-e1d132dfe671" : original.stackTeam }
  let identityCreates = 0
  if (kind === "personal") {
    let found: Array<{ id: string; marker: PersonalTenantMarker }> = []
    await inDO(teamStub(t.team), async (instance) => {
      instance.personalStack = { find: async () => found, members: async () => [t.stackUser], create: async (marker: PersonalTenantMarker) => { identityCreates++; const receipt = { id: t.stackTeam, marker }; found = [receipt]; return receipt } }
    })
  }
  const e = { ...(env as Env), CLOUD_ALLOWED_TEAMS: t.team, CLOUD_VM_TRANSPORT: "vm-api", CLOUD_VM_API_ORIGIN: "https://vm.test", CLOUD_VM_API_SERVICE_KEY: "test-owner-key", CLOUD_VM_API_IMAGE: "cloud-agent", CLOUD_VM_API_IMAGE_REVISION: "v1" }
  const vms = new Map<string, Vm>(), snapshots = new Map<string, { id: string; sourceVmId: string; displayName: string; labels: Record<string, string>; createdAt: string }>()
  const binds = new Map<string, { team: string; machine: string; bind_token: string }>()
  const calls: string[] = []
  let captured: { id: string; sourceVmId: string; displayName: string; labels: Record<string, string>; createdAt: string } | undefined
  let captureReady = false
  let cancelRequested = false
  let cancelReady = false
  let sequence = 0
  const spy = vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const r = new Request(input, init), url = new URL(r.url)
    expect(url.origin).toBe(e.CLOUD_VM_API_ORIGIN)
    expect(r.headers.get("x-cmux-team-id")).toBe(t.stackTeam)
    calls.push(`${r.method} ${url.pathname}`)
    const mesh = { id: "mesh_" + "0".repeat(26), ipv4Cidr: "10.128.0.0/20", displayName: "Cloud", createdAt: "2026-10-19T00:00:00Z" }
    if (url.pathname === "/v1/meshes") return Response.json({ items: [mesh] })
    if (url.pathname === `/v1/meshes/${mesh.id}`) return Response.json(mesh)
    if (url.pathname.startsWith(`/v1/meshes/${mesh.id}/vms/`)) {
      const vmId = url.pathname.split("/").at(-1)!
      return Response.json({ meshId: mesh.id, vmId, ipv4: `10.128.0.${Number(vmId.slice(-2)) + 5}`, attachedAt: mesh.createdAt })
    }
    const parts = url.pathname.split("/"), id = parts[3] ?? ""
    const selected = (labels: Record<string, string>, selectors: string[]) => selectors.every((s) => { const at = s.indexOf("="); return labels[s.slice(0, at)] === s.slice(at + 1) })
    if (r.method === "GET" && (url.pathname === "/v1/vms" || url.pathname === "/v1/snapshots")) {
      expect(url.searchParams.get("createdBy")).toBe("caller")
      return Response.json({ items: url.pathname === "/v1/vms" ? [...vms.values()].filter((v) => selected(v.labels, url.searchParams.getAll("label"))) : [...snapshots.values()].filter((s) => selected(s.labels, (url.searchParams.get("labels") ?? "").split(","))), nextCursor: null })
    }
    if (url.pathname === "/v1/snapshot-creations") return Response.json({ items: [], nextCursor: null });
    if (url.pathname === "/v1/snapshot-creations/by-key/cancel") {
      const body = await r.json() as { expectedSnapshotId: string | null };
      expect(body.expectedSnapshotId).toBe(captured?.id ?? null);
      cancelRequested = true;
      const finished = kind !== "cancel-capture" || cancelReady;
      if (finished && captured) snapshots.delete(captured.id);
      return Response.json(captured ? { state: finished ? "cancelled" : "cancelling", id: captured.id, receipt: captured } : { state: "fenced", id: null });
    }
    if (url.pathname === "/v1/snapshot-creations/by-key") {
      return captured ? Response.json({ id: captured.id, state: cancelRequested && cancelReady ? "deleted" : snapshots.has(captured.id) ? "committed" : "pending", receipt: captured, ...(cancelRequested ? { cancellation: cancelReady ? "completed" : "requested" } : {}) }) : new Response(null, { status: 404 });
    }
    if (url.pathname === `/v1/snapshot-creations/${captured?.id}/reconcile`) {
      if (!captured) throw new Error("missing capture");
      if (captureReady) snapshots.set(captured.id, captured);
      return Response.json({ id: captured.id, state: captureReady ? "committed" : "pending", receipt: captured });
    }
    if (r.method === "POST" && url.pathname === "/v1/vms") {
      const body = await r.json() as { displayName: string; labels: Record<string, string>; image?: { id: string; revision: string }; snapshotId?: string }
      const vm: Vm = { id: `vm_${String(++sequence).padStart(26, "0")}`, displayName: body.displayName, labels: body.labels, state: "running", resources: { vcpus: 2, memoryMib: 4096, diskMib: 16384 }, idleTimeoutSeconds: -1, maxRunSeconds: null, autoDeleteSeconds: null, createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() }
      if (body.snapshotId) expect(snapshots.has(body.snapshotId)).toBe(true)
      vms.set(vm.id, vm)
      return Response.json({ ...vm, ...(body.image ? { bootImage: { ...body.image, displayName: "Cloud" } } : {}), initialNetwork: { publicEgress: true, httpsProxyHosts: [] } }, { status: 201 })
    }
    if (r.method === "DELETE") {
      if (parts[2] === "vms") vms.delete(id)
      else snapshots.delete(id)
      return new Response(null, { status: 204 })
    }
    const vm = vms.get(id)
    if (!vm) return new Response(null, { status: 404 })
    if (r.method === "PUT") {
      binds.set(id, JSON.parse(await r.text()))
      return new Response(null, { status: 204 })
    }
    if (parts[4] === "snapshots") {
      const body = await r.json() as { displayName: string; labels: Record<string, string> }
      if ((kind === "lost-capture" || kind === "cancel-capture") && captured) return Response.json({ _tag: "ServiceUnavailable", message: "capture uncertain", pendingSnapshotId: captured.id }, { status: 503 })
      const snapshot = { ...body, id: `snap_${String(++sequence).padStart(26, "0")}`, sourceVmId: id, createdAt: new Date().toISOString() }
      if (kind === "lost-capture" || kind === "cancel-capture") { captured = snapshot; return Response.json({ _tag: "ServiceUnavailable", message: "capture uncertain", pendingSnapshotId: snapshot.id }, { status: 503 }) }
      snapshots.set(snapshot.id, snapshot)
      return Response.json({ ...snapshot, lastUsedAt: null, ttlSeconds: null, autoDeleteSeconds: null }, { status: 201 })
    }
    const current = parts[4] === "pause" ? { ...vm, state: "paused" as const } : parts[4] === "start" ? { ...vm, state: "running" as const } : vm
    vms.set(id, current)
    return Response.json(current)
  })
  try {
    const key = await vmKey()
    const result = await inDO(e.CLOUD_DO.get(e.CLOUD_DO.idFromName(t.team)), async (_instance, state) => {
      let owner = new CloudDO(state, e)
      const principal = { identity: `user:${t.user}`, kind: "session" as const, user: t.user, team: t.team }
      const submit = async (op: string, params: unknown) => {
        const r: SubmitResult = await owner.submit(t.team, principal, { t: "op", op, params, idempotency_key: crypto.randomUUID(), origin: "user" })
        const answer = r.frames.find((f) => f.t === "result" || f.t === "reject")
        if (answer?.t !== "result") throw new Error(`owner refused ${op}: ${answer?.t === "reject" ? answer.code : "no answer"}`)
        return answer.value as { machine?: { id: string }; snapshot?: { id: string } }
      }
      expect((await owner.readOp(t.team, principal, "cloud.machine.list", {})).ok).toBe(true)
      expect(identityCreates).toBe(0)
      const first = await submit("cloud.machine.create", { size: { cpu: 2, memory_mb: 4096, disk_mb: 16384 } })
      const apiMachine = first.machine!.id
      const bind = [...binds.values()].find((b) => b.machine === apiMachine)
      if (!bind) throw new Error("no API bind file")
      expect(await owner.bindMachine(t.team, { ...bind, wg_public_key: WG_KEY, daemon: DAEMON, install_public_jwk: key.jwk })).toMatchObject({ ok: true })
      // A fresh owner instance reads the same persisted rows with a different creation default.
      owner = new CloudDO(state, { ...e, CLOUD_VM_TRANSPORT: "direct" })
      await submit("cloud.machine.pause", { machine: apiMachine })
      await submit("cloud.machine.start", { machine: apiMachine })
      let saved: { snapshot?: { id: string } };
      if (kind === "cancel-capture") {
        const creating = { t: "op" as const, op: "cloud.snapshot.create", params: { machine: apiMachine }, idempotency_key: crypto.randomUUID(), origin: "user" as const };
        expect((await owner.submit(t.team, principal, creating)).frames).toContainEqual(expect.objectContaining({ t: "reject", code: "mutation.indeterminate" }));
        const listed = await owner.readOp(t.team, principal, "cloud.snapshot.list", { machine: apiMachine });
        if (!listed.ok) throw new Error("snapshot list refused");
        const id = (listed.value as { snapshots: Array<{ id: string }> }).snapshots[0]?.id;
        if (!id) throw new Error("snapshot missing");
        const deleting = { t: "op" as const, op: "cloud.snapshot.delete", params: { snapshot: id }, idempotency_key: crypto.randomUUID(), origin: "user" as const };
        expect((await owner.submit(t.team, principal, deleting)).frames).toContainEqual(expect.objectContaining({ t: "reject", code: "mutation.indeterminate" }));
        expect(cancelRequested).toBe(true);
        for (let i = 0; i < 6; i++) { await owner.fakeControl({ advance_ms: 400_000 }); await owner.alarm(); }
        expect(await owner.readOp(t.team, principal, "cloud.snapshot.list", { machine: apiMachine })).toMatchObject({ ok: true, value: { snapshots: [{ id, status: "deleting" }] } });
        const held = await owner.readOp(t.team, principal, "cloud.plan.get", {});
        if (!held.ok) throw new Error("usage read refused");
        expect((held.value as { usage: { saved: number } }).usage.saved).toBe(1);
        expect((await owner.submit(t.team, principal, creating)).frames).toContainEqual(expect.objectContaining({ t: "reject", code: "cloud.provider.unavailable" }));
        const source = [...vms.values()].find((v) => v.labels.cmux_next_machine === apiMachine);
        if (!source) throw new Error("source missing");
        vms.delete(source.id); cancelReady = true;
        owner = new CloudDO(state, { ...e, CLOUD_ALLOWED_TEAMS: "", CLOUD_VM_TRANSPORT: "direct" });
        await owner.readOp(t.team, principal, "cloud.snapshot.list", { machine: apiMachine });
        await owner.fakeControl({ advance_ms: 4_000_000 }); await owner.alarm();
        expect(await owner.readOp(t.team, principal, "cloud.snapshot.list", { machine: apiMachine })).toMatchObject({ ok: true, value: { snapshots: [] } });
        const released = await owner.readOp(t.team, principal, "cloud.plan.get", {});
        if (!released.ok) throw new Error("usage read refused");
        expect((released.value as { usage: { saved: number } }).usage.saved).toBe(0);
        expect(calls.filter((c) => c.endsWith("/snapshots") && c.startsWith("POST"))).toHaveLength(1);
        await submit("cloud.machine.delete", { machine: apiMachine });
        return owner.fakeControl({});
      }
      if (kind === "lost-capture") {
        const frame = { t: "op" as const, op: "cloud.snapshot.create", params: { machine: apiMachine }, idempotency_key: crypto.randomUUID(), origin: "user" as const };
        const first = await owner.submit(t.team, principal, frame);
        expect(first.frames).toContainEqual(expect.objectContaining({ t: "reject", code: "mutation.indeterminate" }));
        for (let i = 0; i < 6; i++) { await owner.fakeControl({ advance_ms: 400_000 }); await owner.alarm(); }
        const list = await owner.readOp(t.team, principal, "cloud.snapshot.list", { machine: apiMachine });
        expect(list).toMatchObject({ ok: true, value: { snapshots: [{ status: "creating" }] } });
        const usage = await owner.readOp(t.team, principal, "cloud.plan.get", {});
        if (!usage.ok || !list.ok) throw new Error("snapshot or usage read refused");
        expect((usage.value as { usage: { saved: number } }).usage.saved).toBe(1);
        expect((await owner.fakeControl({})).pending).toBe(1);
        const snapshotId = (list.value as { snapshots: Array<{ id: string }> }).snapshots[0]?.id;
        if (!snapshotId) throw new Error("snapshot row missing");
        saved = { snapshot: { id: snapshotId } };
        const source = [...vms.values()].find((v) => v.labels.cmux_next_machine === apiMachine);
        if (!source) throw new Error("missing source");
        vms.delete(source.id);
        captureReady = true;
        // A fresh owner must reconcile retained work even after the plan and creation default change.
        owner = new CloudDO(state, { ...e, CLOUD_ALLOWED_TEAMS: "", CLOUD_VM_TRANSPORT: "direct" });
        await owner.readOp(t.team, principal, "cloud.snapshot.list", { machine: apiMachine });
        await owner.fakeControl({ advance_ms: 4_000_000 }); await owner.alarm();
        expect(await owner.readOp(t.team, principal, "cloud.snapshot.list", { machine: apiMachine })).toMatchObject({ ok: true, value: { snapshots: [{ id: snapshotId, status: "ready" }] } });
        expect(calls.filter((c) => c.endsWith("/snapshots") && c.startsWith("POST"))).toHaveLength(1);
        owner = new CloudDO(state, { ...e, CLOUD_VM_TRANSPORT: "direct" });
      } else saved = await submit("cloud.snapshot.create", { machine: apiMachine });
      const restored = await submit("cloud.snapshot.restore", { snapshot: saved.snapshot!.id })
      const legacy = await submit("cloud.machine.create", { size: { cpu: 2, memory_mb: 4096, disk_mb: 16384 } })
      await submit("cloud.machine.delete", { machine: apiMachine })
      await submit("cloud.machine.delete", { machine: restored.machine!.id })
      await submit("cloud.snapshot.delete", { snapshot: saved.snapshot!.id })
      await submit("cloud.machine.delete", { machine: legacy.machine!.id })
      return owner.fakeControl({})
    })
    expect(identityCreates).toBe(kind === "personal" ? 1 : 0)
    expect(result).toMatchObject({ creates: kind === "cancel-capture" ? 0 : 1, deletes: kind === "cancel-capture" ? 0 : 1, pending: 0 })
    expect(vms.size).toBe(0)
    expect(snapshots.size).toBe(0)
    expect(calls.filter((c) => c === "POST /v1/vms")).toHaveLength(kind === "cancel-capture" ? 1 : 2)
    expect(calls.some((c) => c.endsWith("/pause"))).toBe(true)
    expect(calls.some((c) => c.endsWith("/start"))).toBe(true)
  } finally { spy.mockRestore() }
}, 60_000)
