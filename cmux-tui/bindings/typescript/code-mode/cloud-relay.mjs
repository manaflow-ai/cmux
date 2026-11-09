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
/** A relay op's params as its cloud.* op takes them: `vm_id` is `machine`, `snapshot_id` is `snapshot`. */
function aliasParams(op, params) {
  const out = {};
  for (const [name, value] of Object.entries(params)) {
    const key = name === "vm_id" ? "machine" : name === "snapshot_id" ? "snapshot" : name;
    if (key === "machine" && (op === "cloud.snapshot.restore" || op === "cloud.snapshot.delete")) continue;
    out[key] = value;
  }
  return out;
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
      const op = OP_ALIASES[operation] ?? operation;
      const opParams = OP_ALIASES[operation] ? aliasParams(op, params) : params;
      const descriptor = catalog.operations?.[operation];
      const isMutation = descriptor ? descriptor.class === "mutation" : MUTATIONS.has(operation);
      path = isMutation ? "/v1/ops" : "/v1/read";
      payload = isMutation ? { op, params: opParams, idempotency_key: requestIdempotencyKey ?? randomUUID(), origin: "script" } : { op, params: opParams };
    }
    const response = await fetchImpl(`${apiUrl.replace(/\/$/, "")}${path}${query}`, {
      method,
      headers: { authorization: `Bearer ${bearerToken}`, ...(payload === undefined ? {} : { "content-type": "application/json" }), ...(requestIdempotencyKey ? { "idempotency-key": requestIdempotencyKey } : {}) },
      ...(payload === undefined ? {} : { body: JSON.stringify(payload) }),
    });
    let value;
    try { value = await response.json(); } catch { value = null; }
    if (!response.ok) throw new Error(typeof value?.message === "string" ? value.message : typeof value?.error === "string" ? value.error : `Cloud API request failed (${response.status})`);
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
