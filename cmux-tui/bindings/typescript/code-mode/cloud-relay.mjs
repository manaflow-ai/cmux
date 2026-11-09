import { createServer } from "node:net";
import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";

// A machine's exec and file routes: cmux-platform's /v1/cloud/machines/{id}/exec and /fs/*.
const MACHINE_IO = new Set(["vm.exec", "vm.fs.list", "vm.fs.read", "vm.fs.write", "vm.fs.mkdir", "vm.fs.remove", "vm.fs.stat"]);
// The relay's machine and snapshot names are cmux-platform's cloud.* ops (POST /v1/ops or /v1/read), as the
// Cloud app server aliases them (first-party-apps/cloud/server/src/ops/mod.rs ALIASES).
const OP_ALIASES = {
  "vm.list": "cloud.machine.list", "vm.get": "cloud.machine.get", "vm.create": "cloud.machine.create",
  "vm.update": "cloud.machine.rename", "vm.start": "cloud.machine.start", "vm.resume": "cloud.machine.start",
  "vm.pause": "cloud.machine.pause", "vm.resize": "cloud.machine.resize", "vm.delete": "cloud.machine.delete",
  "vm.snapshot.list": "cloud.snapshot.list", "vm.snapshot.create": "cloud.snapshot.create",
  "vm.snapshot.restore": "cloud.snapshot.restore", "vm.snapshot.delete": "cloud.snapshot.delete",
};
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
  "cloud.machine.list": ["cursor", "limit"], "cloud.machine.get": ["machine"],
  "cloud.machine.create": ["name", "size", "image", "from_snapshot"],
  "cloud.machine.rename": ["machine", "name"],
  "cloud.machine.start": ["machine"], "cloud.machine.pause": ["machine"],
  "cloud.machine.resize": ["machine", "size"], "cloud.machine.delete": ["machine"],
  "cloud.snapshot.list": ["machine"], "cloud.snapshot.create": ["machine", "name"],
  "cloud.snapshot.restore": ["snapshot", "name"], "cloud.snapshot.delete": ["snapshot"],
};
// cmux-platform's own defaults for a create that names no size (Plan.ts DEFAULT_SIZE); memory is the plan's.
const DEFAULT_CREATE_SIZE = { cpu: 2, disk_mb: 16384 };
// A size field as the classic routes and the protocol spell it (the classic resize took cpu, memoryMb and
// storageMb; the classic create memoryMb), as cloud.*'s `size`.
const SIZE_NAMES = { cpu: "cpu", memoryMb: "memory_mb", memory_mb: "memory_mb", storageMb: "disk_mb", diskMb: "disk_mb", disk_mb: "disk_mb" };
const REVISION = ["expected_revision", "expectedRevision"];
// Every field each aliased relay op takes: its old classic /api/vm body's fields (the relay passed them
// through before cmux-platform) and the protocol's own names. A field outside its op's list is refused
// before any request, never dropped (cloud-relay.test.mjs holds every old field to a protocol field).
export const ACCEPTED = {
  "vm.list": ["cursor", "limit"],
  "vm.get": ["vm_id", "machine"],
  "vm.create": ["name", "displayName", "size", ...Object.keys(SIZE_NAMES), "image", "from_snapshot", "fromSnapshot", "snapshot_id", ...REVISION],
  "vm.update": ["vm_id", "machine", "name", "displayName", ...REVISION],
  "vm.start": ["vm_id", "machine", ...REVISION], "vm.resume": ["vm_id", "machine", ...REVISION],
  "vm.pause": ["vm_id", "machine", ...REVISION], "vm.delete": ["vm_id", "machine", ...REVISION],
  "vm.resize": ["vm_id", "machine", "size", ...Object.keys(SIZE_NAMES), ...REVISION],
  "vm.snapshot.list": ["vm_id", "machine"],
  "vm.snapshot.create": ["vm_id", "machine", "name", ...REVISION],
  "vm.snapshot.restore": ["vm_id", "snapshot_id", "snapshotId", "snapshot", "name", ...REVISION],
  "vm.snapshot.delete": ["vm_id", "snapshot_id", "snapshotId", "snapshot", ...REVISION],
};
// Old classic fields this Cloud has no protocol field for: refused with why, not dropped.
const NOT_ON_THIS_CLOUD = {
  autosize: "the create's autosize is not available on this Cloud yet; pass memoryMb",
  idlePauseMinutes: "set the idle pause with cloud.machine.idle_policy.set after the create",
};
function sizeOf(operation, params) {
  const size = {};
  const nested = params.size === undefined || params.size === null ? {} : params.size;
  if (typeof nested !== "object" || Array.isArray(nested)) throw new Error(`${operation}: size must be an object`);
  for (const [source, at] of [[params, ""], [nested, "size."]]) {
    for (const [name, value] of Object.entries(source)) {
      if (source === params && !SIZE_NAMES[name]) continue;
      if (!SIZE_NAMES[name]) throw new Error(`${operation} takes no ${at}${name}`);
      if (value !== undefined && value !== null) size[SIZE_NAMES[name]] = value;
    }
  }
  return size;
}
/** A relay op's params as its cloud.* op takes them: `vm_id` is `machine`, `snapshot_id` or `snapshotId` is
 * `snapshot`, `displayName` is `name`, a create's or resize's sizing is `size` (never empty: a create with none
 * gets the platform's default, a resize with none sends none and is refused). Any other field is refused. */
function aliasParams(operation, op, params) {
  for (const field of Object.keys(params)) {
    if (NOT_ON_THIS_CLOUD[field]) throw new Error(`${operation}: ${NOT_ON_THIS_CLOUD[field]}`);
    if (!ACCEPTED[operation].includes(field)) throw new Error(`${operation} takes no ${field}`);
  }
  const named = { machine: params.machine ?? params.vm_id, snapshot: params.snapshot ?? params.snapshot_id ?? params.snapshotId,
    name: params.name ?? params.displayName, image: params.image, cursor: params.cursor, limit: params.limit };
  if (op === "cloud.machine.rename" && (named.name === undefined || named.name === null || named.name === "")) {
    throw new Error(`${operation} needs a name; this Cloud cannot clear one`);
  }
  if (op === "cloud.machine.create" || op === "cloud.machine.resize") {
    const size = sizeOf(operation, params);
    named.size = Object.keys(size).length ? size : op === "cloud.machine.create" ? { ...DEFAULT_CREATE_SIZE } : undefined;
  }
  if (op === "cloud.machine.create") named.from_snapshot = params.from_snapshot ?? params.fromSnapshot ?? params.snapshot_id;
  const out = {};
  for (const field of OP_FIELDS[op]) if (named[field] !== undefined && named[field] !== null) out[field] = named[field];
  return out;
}
/** The envelope's `expected_revision`: the caller's, in either spelling, as the decimal string Revision is. */
function expectedRevision(params) {
  const value = params.expected_revision ?? params.expectedRevision;
  return value === undefined || value === null ? undefined : String(value);
}

/**
 * Host-owned Cloud broker. The bearer is read only here and is never passed to
 * code mode or bwrap. Routes are a fixed operation map, never caller URLs.
 */
export function createCloudBroker({ apiUrl, bearerToken, fetchImpl = fetch, catalog = {}, allowedOperations = undefined, fixture = undefined } = {}) {
  if (!fixture && (!apiUrl || !bearerToken)) throw new Error("Cloud relay requires host credentials");
  const catalogOps = new Set(allowedOperations ?? Object.keys(catalog.operations ?? {}));
  async function request(operation, params, idempotencyKey) {
    if (!catalogOps.has(operation)) throw new Error(`Cloud operation is not in the catalog: ${operation}`);
    if (fixture && Object.hasOwn(fixture, operation)) return structuredClone(fixture[operation]);
    const requestIdempotencyKey = operation === "vm.snapshot.create"
      ? idempotencyKey ?? randomUUID()
      : idempotencyKey;
    let method = "POST", path, query = "", payload;
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
    return value?.value ?? value;
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
