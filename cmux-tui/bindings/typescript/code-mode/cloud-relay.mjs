import { createServer } from "node:net";
import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";

// A machine's exec and file routes: cmux-platform's /v1/cloud/machines/{id}/exec and /fs/*.
const MACHINE_IO = new Set(["vm.exec", "vm.fs.list", "vm.fs.read", "vm.fs.write", "vm.fs.mkdir", "vm.fs.remove", "vm.fs.stat"]);
// The relay's machine and snapshot names a script may send are cmux-platform's cloud.* ops (POST /v1/ops or
// /v1/read), as the Cloud app server aliases them (first-party-apps/cloud/server/src/ops/mod.rs ALIASES).
const OP_ALIASES = {
  "vm.list": "cloud.machine.list", "vm.get": "cloud.machine.get", "vm.update": "cloud.machine.rename",
  "vm.start": "cloud.machine.start", "vm.resume": "cloud.machine.start", "vm.pause": "cloud.machine.pause",
  "vm.snapshot.list": "cloud.snapshot.list",
};
// The cloud.* ops cmux-platform takes only from a person (origin "user": the Cloud app server's
// Kind::UserOnly, first-party-apps/cloud/server/src/ops/mod.rs): money and destructive machine changes. A
// script never claims to be the person, so the relay does not offer these and refuses them by name.
export const USER_ONLY = new Set(["vm.create", "vm.resize", "vm.delete", "vm.snapshot.create", "vm.snapshot.restore", "vm.snapshot.delete"]);
export const USER_ONLY_REFUSAL = "Cloud machine changes need you in the app; scripts can't create, resize or delete machines or take, restore or delete snapshots.";
const MUTATIONS = new Set(["tunnel.attach", "tunnel.detach", "tunnel.rotate-key", "firewall.create", "firewall.delete"]);
const VM_ID = /^[A-Za-z0-9._:-]{1,256}$/;
const MAX_FRAME = 4 * 1024 * 1024;

function vmId(params, operation) {
  if (typeof params.vm_id !== "string" || !VM_ID.test(params.vm_id)) throw new Error(`${operation} requires vm_id`);
  return params.vm_id;
}
function guestPath(params, operation) {
  if (typeof params.path !== "string" || !params.path.startsWith("/") || params.path.includes("\0") || params.path.split("/").includes("..") || Buffer.byteLength(params.path) > 4096) throw new Error(`${operation} requires an absolute guest path without '..'`);
  return params.path;
}
function bodyWithout(params, ...names) { const body = { ...params }; for (const name of names) delete body[name]; return body; }
// Each aliased cloud.* op's params fields (backend/catalog/cloud-operations.json, `extra: false`). An op's
// `expected_revision` is not a param: it rides the /v1/ops envelope (cmux-platform CloudOps.ts OpRequest).
// cloud-relay.test.mjs checks this table against the catalog.
export const OP_FIELDS = {
  "cloud.machine.list": ["cursor", "limit"], "cloud.machine.get": ["machine"], "cloud.machine.rename": ["machine", "name"],
  "cloud.machine.start": ["machine"], "cloud.machine.pause": ["machine"], "cloud.snapshot.list": ["machine"],
};
const REVISION = ["expected_revision", "expectedRevision"];
// Every field each aliased relay op takes: its old classic /api/vm body's fields (the relay passed them
// through before cmux-platform; rename's was displayName) and the protocol's own names. A field outside its
// op's list is refused before any request, never dropped (cloud-relay.test.mjs walks the old fields).
export const ACCEPTED = {
  "vm.list": ["cursor", "limit"],
  "vm.get": ["vm_id", "machine"],
  "vm.update": ["vm_id", "machine", "name", "displayName", ...REVISION],
  "vm.start": ["vm_id", "machine", ...REVISION], "vm.resume": ["vm_id", "machine", ...REVISION],
  "vm.pause": ["vm_id", "machine", ...REVISION],
  "vm.snapshot.list": ["vm_id", "machine"],
};
/** A relay op's params as its cloud.* op takes them: `vm_id` is `machine` and `displayName` is `name`. Any
 * other field is refused, and so is a rename that would clear the name (the protocol needs one). */
function aliasParams(operation, op, params) {
  for (const field of Object.keys(params)) if (!ACCEPTED[operation].includes(field)) throw new Error(`${operation} takes no ${field}`);
  const named = { machine: params.machine ?? params.vm_id, name: params.name ?? params.displayName, cursor: params.cursor, limit: params.limit };
  if (op === "cloud.machine.rename" && (named.name === undefined || named.name === null || named.name === "")) {
    throw new Error(`${operation} needs a name; this Cloud cannot clear one`);
  }
  const out = {};
  for (const field of OP_FIELDS[op]) if (named[field] !== undefined && named[field] !== null) out[field] = named[field];
  return out;
}
/** The envelope's `expected_revision`: the caller's, in either spelling, as the decimal string Revision is. */
function expectedRevision(params) {
  const value = params.expected_revision ?? params.expectedRevision;
  return value === undefined || value === null ? undefined : String(value);
}

// The answers the relay gave before cmux-platform were classic /api/vm's: a machine record with camelCase
// fields (cmux-cloud-machine record.rs `from_classic` reads them), `{vms, limits}` for a list and
// `{snapshots}` for snapshots. Each aliased op's platform answer is turned back into that shape; the
// platform's own fields stay beside the old ones. Classic fields this Cloud has no source for are null:
// CLASSIC_UNSOURCED names them (cloud-relay.test.mjs checks every old field is present).
export const CLASSIC_MACHINE_FIELDS = ["id", "provider", "status", "displayName", "slug", "kind", "image", "imageVersion", "createdAt", "createdByUserId", "address", "size", "capabilities", "pauseReason", "idlePauseMinutes", "idlePause", "updatedAt", "hourlyRateUsd", "runningSince", "sizePick", "error"];
export const CLASSIC_SIZE_FIELDS = ["name", "cpu", "memoryMb", "storageMb"];
export const CLASSIC_LIMITS_FIELDS = ["maxActiveVms", "activeVmCount", "planId", "memoryOptionsMb", "vcpusByMemoryMb", "lockedMemoryOptionsMb"];
export const CLASSIC_UNSOURCED = ["slug", "kind", "address", "idlePause", "updatedAt", "hourlyRateUsd", "runningSince", "sizePick", "size.name", "limits.maxActiveVms", "limits.planId", "limits.memoryOptionsMb", "limits.vcpusByMemoryMb", "limits.lockedMemoryOptionsMb"];
const ACTIVE = new Set(["provisioning", "starting", "running"]);
const or = (value) => (value === undefined ? null : value);
export function classicMachine(machine) {
  if (!machine || typeof machine !== "object") return machine;
  const size = machine.size && typeof machine.size === "object" ? machine.size : {};
  const image = machine.image && typeof machine.image === "object" ? machine.image : {};
  const idle = machine.idle_policy?.idle_seconds;
  return {
    ...machine,
    provider: "cmux-next", displayName: or(machine.name), slug: null, kind: null,
    image: or(image.id), imageVersion: or(image.daemon_version), image_ref: machine.image,
    createdAt: or(machine.created_at), createdByUserId: or(machine.creator), address: null,
    size: { ...size, name: null, cpu: or(size.cpu), memoryMb: or(size.memory_mb), storageMb: or(size.disk_mb) },
    capabilities: or(machine.provider_operations), pauseReason: or(machine.pause_reason),
    idlePauseMinutes: typeof idle === "number" ? Math.round(idle / 60) : null, idlePause: null, updatedAt: null,
    hourlyRateUsd: null, runningSince: null, sizePick: null, error: or(machine.error),
  };
}
export function classicSnapshot(snapshot) {
  return snapshot && typeof snapshot === "object" ? { ...snapshot, snapshotId: snapshot.id, name: or(snapshot.name) } : snapshot;
}
/** An aliased op's platform answer in the shape the relay returned before cmux-platform. */
export function classicAnswer(op, value) {
  if (!value || typeof value !== "object") return value;
  if (op === "cloud.machine.list") {
    const machines = Array.isArray(value.machines) ? value.machines : [];
    const vms = machines.map(classicMachine);
    const activeVmCount = machines.filter((machine) => ACTIVE.has(machine?.status)).length;
    return { ...value, vms, limits: { maxActiveVms: null, activeVmCount, planId: null, memoryOptionsMb: [], vcpusByMemoryMb: {}, lockedMemoryOptionsMb: null } };
  }
  if (op === "cloud.machine.get") return classicMachine(value);
  if (op === "cloud.snapshot.list") return { ...value, snapshots: (Array.isArray(value.snapshots) ? value.snapshots : []).map(classicSnapshot) };
  if (value.machine && typeof value.machine === "object") return { ...classicMachine(value.machine), machine: value.machine };
  return value;
}

/**
 * Host-owned Cloud broker. The bearer is read only here and is never passed to
 * code mode or bwrap. Routes are a fixed operation map, never caller URLs.
 */
export function createCloudBroker({ apiUrl, bearerToken, fetchImpl = fetch, catalog = {}, allowedOperations = undefined, fixture = undefined } = {}) {
  if (!fixture && (!apiUrl || !bearerToken)) throw new Error("Cloud relay requires host credentials");
  const catalogOps = new Set(allowedOperations ?? Object.keys(catalog.operations ?? {}));
  async function request(operation, params, idempotencyKey) {
    if (USER_ONLY.has(operation)) throw new Error(USER_ONLY_REFUSAL);
    if (!catalogOps.has(operation)) throw new Error(`Cloud operation is not in the catalog: ${operation}`);
    if (fixture && Object.hasOwn(fixture, operation)) return structuredClone(fixture[operation]);
    const requestIdempotencyKey = idempotencyKey;
    let method = "POST", path, query = "", payload, aliasOp;
    if (MACHINE_IO.has(operation)) {
      const base = `/v1/cloud/machines/${encodeURIComponent(vmId(params, operation))}`;
      if (operation === "vm.exec") { path = `${base}/exec`; payload = bodyWithout(params, "vm_id"); }
      else {
        const fsOp = operation.slice("vm.fs.".length); path = `${base}/fs/${fsOp === "list" ? "dir" : fsOp}`;
        if (fsOp === "list" || fsOp === "read" || fsOp === "stat") { method = "GET"; query = `?path=${encodeURIComponent(guestPath(params, operation))}`; }
        else if (fsOp === "write" || fsOp === "mkdir") { payload = bodyWithout(params, "vm_id"); }
        else { method = "DELETE"; query = `?path=${encodeURIComponent(guestPath(params, operation))}`; }
      }
    } else {
      // A protocol op: its catalog class picks /v1/ops (a mutation, with a key and the script origin) or /v1/read.
      const aliased = Object.hasOwn(OP_ALIASES, operation);
      const op = aliased ? OP_ALIASES[operation] : operation;
      if (aliased) aliasOp = op;
      const opParams = aliased ? aliasParams(operation, op, params) : params;
      const descriptor = catalog.operations?.[operation];
      const isMutation = descriptor ? descriptor.class === "mutation" : MUTATIONS.has(operation);
      const revision = aliased && isMutation ? expectedRevision(params) : undefined;
      path = isMutation ? "/v1/ops" : "/v1/read";
      payload = isMutation
        ? { op, params: opParams, idempotency_key: requestIdempotencyKey ?? randomUUID(), origin: "script", ...(revision === undefined ? {} : { expected_revision: revision }) }
        : { op, params: opParams };
    }
    const response = await fetchImpl(`${apiUrl.replace(/\/$/, "")}${path}${query}`, {
      method,
      headers: { authorization: `Bearer ${bearerToken}`, ...(payload === undefined ? {} : { "content-type": "application/json" }), ...(requestIdempotencyKey ? { "idempotency-key": requestIdempotencyKey } : {}) },
      ...(payload === undefined ? {} : { body: JSON.stringify(payload) }),
    });
    let value;
    try { value = await response.json(); } catch { value = null; }
    if (!response.ok) throw new Error(typeof value?.message === "string" ? value.message : typeof value?.error === "string" ? value.error : `Cloud API request failed (${response.status})`);
    // A protocol op's refusal (quota, plan, validation) is a 200 whose body says `ok: false`.
    if (value?.ok === false) {
      const error = value.error;
      throw new Error(typeof error?.message === "string" ? error.message : typeof error?.code === "string" ? error.code : typeof error === "string" ? error : "Cloud operation refused");
    }
    const answer = value?.value ?? value;
    return aliasOp ? classicAnswer(aliasOp, answer) : answer;
  }
  return { request };
}

export function serveCloudRelay(socketPath, broker) {
  const server = createServer((client) => {
    let pending = "";
    const finish = () => client.destroy();
    client.setEncoding("utf8");
    client.on("data", (chunk) => {
      pending += chunk;
      if (Buffer.byteLength(pending) > MAX_FRAME) return finish();
      let end;
      while ((end = pending.indexOf("\n")) >= 0) {
        const line = pending.slice(0, end); pending = pending.slice(end + 1);
        void handle(line, client, broker).catch((error) => {
          let id; try { id = JSON.parse(line)?.id; } catch {}
          send(client, { protocol: "cmux.cloud/1", type: "response", ...(typeof id === "string" ? { id } : {}), ok: false, error: { message: String(error?.message ?? error) } });
        });
      }
    });
    client.on("error", finish);
  });
  server.listen(socketPath);
  return server;
}
async function handle(line, client, broker) {
  const message = JSON.parse(line);
  if (message?.protocol !== "cmux.cloud/1" || message?.type !== "request" || typeof message.id !== "string" || typeof message.operation !== "string" || !message.params || typeof message.params !== "object" || Array.isArray(message.params)) throw new Error("invalid Cloud relay request");
  const value = await broker.request(message.operation, message.params, message.idempotency_key);
  send(client, { protocol: "cmux.cloud/1", type: "response", id: message.id, ok: true, value });
}
function send(client, message) { if (!client.destroyed) client.write(`${JSON.stringify(message)}\n`); }
