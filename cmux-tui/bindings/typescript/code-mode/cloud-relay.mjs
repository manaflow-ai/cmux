import { createServer } from "node:net";
import { readFile } from "node:fs/promises";

const VM = new Set(["vm.list", "vm.get", "vm.create", "vm.update", "vm.start", "vm.resume", "vm.pause", "vm.resize", "vm.delete", "vm.snapshot.list", "vm.snapshot.create", "vm.snapshot.restore", "vm.snapshot.delete", "vm.exec", "vm.fs.list", "vm.fs.read", "vm.fs.write", "vm.fs.mkdir", "vm.fs.remove", "vm.fs.stat"]);
const CLOUD = new Set(["network.list", "tunnel.attach", "tunnel.detach", "tunnel.rotate-key", "firewall.list", "firewall.get", "firewall.create", "firewall.delete"]);
const FS = new Set(["vm.fs.list", "vm.fs.read", "vm.fs.stat", "vm.fs.write", "vm.fs.mkdir", "vm.fs.remove"]);
const MUTATIONS = new Set(["vm.create", "vm.update", "vm.start", "vm.resume", "vm.pause", "vm.resize", "vm.delete", "vm.snapshot.create", "vm.snapshot.restore", "vm.snapshot.delete", "vm.fs.write", "vm.fs.mkdir", "vm.fs.remove", "tunnel.attach", "tunnel.detach", "tunnel.rotate-key", "firewall.create", "firewall.delete"]);
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

/**
 * Host-owned Cloud broker. The bearer is read only here and is never passed to
 * code mode or bwrap. Routes are a fixed operation map, never caller URLs.
 */
export function createCloudBroker({ apiUrl, bearerToken, fetchImpl = fetch, catalog = {}, fixture = undefined } = {}) {
  if (!fixture && (!apiUrl || !bearerToken)) throw new Error("Cloud relay requires host credentials");
  const catalogOps = new Set(Object.keys(catalog.operations ?? {}));
  async function request(operation, params, idempotencyKey) {
    if (!catalogOps.has(operation)) throw new Error(`Cloud operation is not in the catalog: ${operation}`);
    if (fixture && Object.hasOwn(fixture, operation)) return structuredClone(fixture[operation]);
    let method = "GET", path = "/api/vm", query = "", payload;
    if (VM.has(operation)) {
      if (operation === "vm.list") { method = "GET"; }
      else if (operation === "vm.create") { method = "POST"; payload = { ...params }; }
      else {
        const id = vmId(params, operation);
        if (operation === "vm.get") path = `/api/vm/${encodeURIComponent(id)}`;
        else if (operation === "vm.update") { method = "PATCH"; path = `/api/vm/${encodeURIComponent(id)}`; payload = bodyWithout(params, "vm_id"); }
        else if (operation === "vm.delete") { method = "DELETE"; path = `/api/vm/${encodeURIComponent(id)}`; }
        else if (operation === "vm.start" || operation === "vm.resume") { method = "POST"; path = `/api/vm/${encodeURIComponent(id)}/resume`; payload = {}; }
        else if (operation === "vm.pause") { method = "POST"; path = `/api/vm/${encodeURIComponent(id)}/pause`; payload = {}; }
        else if (operation === "vm.resize") { method = "POST"; path = `/api/vm/${encodeURIComponent(id)}/resize`; payload = bodyWithout(params, "vm_id"); }
        else if (operation === "vm.exec") { method = "POST"; path = `/api/vm/${encodeURIComponent(id)}/exec`; payload = bodyWithout(params, "vm_id"); }
        else if (operation.startsWith("vm.fs.")) {
          const fsOp = operation.slice("vm.fs.".length); path = `/api/vm/${encodeURIComponent(id)}/fs/${fsOp === "list" ? "dir" : fsOp}`;
          if (fsOp === "list" || fsOp === "read" || fsOp === "stat") { query = `?path=${encodeURIComponent(guestPath(params, operation))}`; }
          else if (fsOp === "write" || fsOp === "mkdir") { method = "POST"; payload = bodyWithout(params, "vm_id"); }
          else { method = "DELETE"; query = `?path=${encodeURIComponent(guestPath(params, operation))}`; }
        } else if (operation.startsWith("vm.snapshot.")) {
          const snap = operation.slice("vm.snapshot.".length);
          if (snap === "list") path = `/api/vm/${encodeURIComponent(id)}/snapshots`;
          else if (snap === "create") { method = "POST"; path = `/api/vm/${encodeURIComponent(id)}/snapshot`; payload = bodyWithout(params, "vm_id"); }
          else if (snap === "restore") { method = "POST"; path = `/api/vm/${encodeURIComponent(id)}/restore`; payload = bodyWithout(params, "vm_id"); }
          else { method = "DELETE"; path = `/api/vm/${encodeURIComponent(id)}/snapshots/${encodeURIComponent(String(params.snapshot_id ?? ""))}`; }
        }
      }
    } else if (catalogOps.has(operation)) {
      const descriptor = catalog.operations[operation];
      const isMutation = descriptor.class === "mutation";
      method = isMutation ? "POST" : "POST";
      path = isMutation ? "/v1/ops" : "/v1/read";
      payload = isMutation ? { op: operation, params, idempotency_key: idempotencyKey ?? crypto.randomUUID(), origin: "code_mode" } : { op: operation, params };
    } else {
      // Network policy operations are owner-routed through the Cloud API catalog.
      const isMutation = MUTATIONS.has(operation); method = "POST"; path = isMutation ? "/v1/ops" : "/v1/read";
      payload = isMutation ? { op: operation, params, idempotency_key: idempotencyKey ?? crypto.randomUUID(), origin: "code_mode" } : { op: operation, params };
    }
    const response = await fetchImpl(`${apiUrl.replace(/\/$/, "")}${path}${query}`, {
      method,
      headers: { authorization: `Bearer ${bearerToken}`, ...(payload === undefined ? {} : { "content-type": "application/json" }), ...(idempotencyKey ? { "idempotency-key": idempotencyKey } : {}) },
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
