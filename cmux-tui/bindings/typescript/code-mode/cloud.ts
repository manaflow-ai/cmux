import { createConnection, type Socket } from "node:net";
import { randomUUID } from "node:crypto";

export type CloudParams = Readonly<Record<string, unknown>>;
export type CloudValue = Record<string, unknown> | readonly unknown[] | string | number | boolean | null;

export interface CloudTransport {
  request(operation: string, params: CloudParams, idempotencyKey?: string): Promise<CloudValue>;
  close(): void;
}

const VM_ID = /^[A-Za-z0-9._:-]{1,256}$/;
const OPERATION_NAMES = new Set([
  "vm.list", "vm.get", "vm.create", "vm.update", "vm.start", "vm.resume", "vm.pause", "vm.resize", "vm.delete",
  "vm.snapshot.list", "vm.snapshot.create", "vm.snapshot.restore", "vm.snapshot.delete", "vm.exec",
  "vm.fs.list", "vm.fs.read", "vm.fs.write", "vm.fs.mkdir", "vm.fs.remove", "vm.fs.stat",
  "network.list", "tunnel.attach", "tunnel.detach", "tunnel.rotate-key",
  "firewall.list", "firewall.get", "firewall.create", "firewall.delete",
]);

function object(value: CloudValue, operation: string): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${operation} returned a non-object result`);
  }
  return value as Record<string, unknown>;
}
function id(value: unknown, operation: string): string {
  if (typeof value !== "string" || !VM_ID.test(value)) throw new TypeError(`${operation} requires a valid vm_id`);
  return value;
}
function path(value: unknown, operation: string): string {
  if (typeof value !== "string" || !value.startsWith("/") || value.includes("\0") || value.split("/").includes("..")) {
    throw new TypeError(`${operation} requires an absolute path without '..'`);
  }
  return value;
}

/** Typed Cloud owner relay client injected into code mode. */
export class CloudClient {
  constructor(private readonly transport: CloudTransport) {}
  close(): void { this.transport.close(); }
  call(operation: string, params: CloudParams = {}, idempotencyKey?: string): Promise<CloudValue> {
    if (!OPERATION_NAMES.has(operation)) throw new TypeError(`Cloud operation is not in the catalog: ${operation}`);
    return this.transport.request(operation, Object.freeze({ ...params }), idempotencyKey);
  }
  list(): Promise<CloudValue> { return this.call("vm.list"); }
  get(vmId: string): Promise<CloudValue> { return this.call("vm.get", { vm_id: id(vmId, "vm.get") }); }
  create(params: CloudParams, idempotencyKey?: string): Promise<CloudValue> { return this.call("vm.create", params, idempotencyKey); }
  update(vmId: string, fields: CloudParams, idempotencyKey?: string): Promise<CloudValue> { return this.call("vm.update", { vm_id: id(vmId, "vm.update"), ...fields }, idempotencyKey); }
  start(vmId: string, idempotencyKey?: string): Promise<CloudValue> { return this.call("vm.start", { vm_id: id(vmId, "vm.start") }, idempotencyKey); }
  resume(vmId: string, idempotencyKey?: string): Promise<CloudValue> { return this.call("vm.resume", { vm_id: id(vmId, "vm.resume") }, idempotencyKey); }
  pause(vmId: string, idempotencyKey?: string): Promise<CloudValue> { return this.call("vm.pause", { vm_id: id(vmId, "vm.pause") }, idempotencyKey); }
  resize(vmId: string, fields: CloudParams, idempotencyKey?: string): Promise<CloudValue> { return this.call("vm.resize", { vm_id: id(vmId, "vm.resize"), ...fields }, idempotencyKey); }
  delete(vmId: string, idempotencyKey?: string): Promise<CloudValue> { return this.call("vm.delete", { vm_id: id(vmId, "vm.delete") }, idempotencyKey); }
  exec(vmId: string, command: string, timeoutMs?: number): Promise<CloudValue> { return this.call("vm.exec", { vm_id: id(vmId, "vm.exec"), command, ...(timeoutMs === undefined ? {} : { timeoutMs }) }); }
  snapshotList(vmId: string): Promise<CloudValue> { return this.call("vm.snapshot.list", { vm_id: id(vmId, "vm.snapshot.list") }); }
  snapshotCreate(vmId: string, fields: CloudParams = {}, idempotencyKey?: string): Promise<CloudValue> { return this.call("vm.snapshot.create", { vm_id: id(vmId, "vm.snapshot.create"), ...fields }, idempotencyKey); }
  snapshotRestore(vmId: string, snapshotId: string, idempotencyKey?: string): Promise<CloudValue> { return this.call("vm.snapshot.restore", { vm_id: id(vmId, "vm.snapshot.restore"), snapshot_id: snapshotId }, idempotencyKey); }
  snapshotDelete(vmId: string, snapshotId: string, idempotencyKey?: string): Promise<CloudValue> { return this.call("vm.snapshot.delete", { vm_id: id(vmId, "vm.snapshot.delete"), snapshot_id: snapshotId }, idempotencyKey); }
  fsList(vmId: string, guestPath: string): Promise<CloudValue> { return this.call("vm.fs.list", { vm_id: id(vmId, "vm.fs.list"), path: path(guestPath, "vm.fs.list") }); }
  fsRead(vmId: string, guestPath: string): Promise<CloudValue> { return this.call("vm.fs.read", { vm_id: id(vmId, "vm.fs.read"), path: path(guestPath, "vm.fs.read") }); }
  fsWrite(vmId: string, guestPath: string, dataBase64: string, mode?: number, idempotencyKey?: string): Promise<CloudValue> { return this.call("vm.fs.write", { vm_id: id(vmId, "vm.fs.write"), path: path(guestPath, "vm.fs.write"), dataBase64, ...(mode === undefined ? {} : { mode }) }, idempotencyKey); }
  fsMkdir(vmId: string, guestPath: string, idempotencyKey?: string): Promise<CloudValue> { return this.call("vm.fs.mkdir", { vm_id: id(vmId, "vm.fs.mkdir"), path: path(guestPath, "vm.fs.mkdir") }, idempotencyKey); }
  fsRemove(vmId: string, guestPath: string, idempotencyKey?: string): Promise<CloudValue> { return this.call("vm.fs.remove", { vm_id: id(vmId, "vm.fs.remove"), path: path(guestPath, "vm.fs.remove") }, idempotencyKey); }
  fsStat(vmId: string, guestPath: string): Promise<CloudValue> { return this.call("vm.fs.stat", { vm_id: id(vmId, "vm.fs.stat"), path: path(guestPath, "vm.fs.stat") }); }
  networkList(params: CloudParams = {}): Promise<CloudValue> { return this.call("network.list", params); }
  tunnelAttach(params: CloudParams, idempotencyKey?: string): Promise<CloudValue> { return this.call("tunnel.attach", params, idempotencyKey); }
  tunnelDetach(params: CloudParams, idempotencyKey?: string): Promise<CloudValue> { return this.call("tunnel.detach", params, idempotencyKey); }
  tunnelRotateKey(params: CloudParams, idempotencyKey?: string): Promise<CloudValue> { return this.call("tunnel.rotate-key", params, idempotencyKey); }
  firewallList(params: CloudParams = {}): Promise<CloudValue> { return this.call("firewall.list", params); }
  firewallGet(params: CloudParams): Promise<CloudValue> { return this.call("firewall.get", params); }
  firewallCreate(params: CloudParams, idempotencyKey?: string): Promise<CloudValue> { return this.call("firewall.create", params, idempotencyKey); }
  firewallDelete(params: CloudParams, idempotencyKey?: string): Promise<CloudValue> { return this.call("firewall.delete", params, idempotencyKey); }
}

/** Newline framed host transport. It carries no bearer token. */
export class UnixCloudTransport implements CloudTransport {
  private readonly socket: Socket;
  private readonly pending = new Map<string, { resolve: (value: CloudValue) => void; reject: (error: Error) => void }>();
  private buffered = "";
  private closed = false;
  constructor(socketPath: string) {
    this.socket = createConnection(socketPath);
    this.socket.setEncoding("utf8");
    this.socket.on("data", (chunk: string) => this.receive(chunk));
    this.socket.on("error", (error) => this.fail(error));
    this.socket.on("close", () => this.fail(new Error("Cloud relay closed")));
  }
  request(operation: string, params: CloudParams, idempotencyKey?: string): Promise<CloudValue> {
    if (this.closed) return Promise.reject(new Error("Cloud relay is closed"));
    const id = randomUUID();
    const message = JSON.stringify({ protocol: "cmux.cloud/1", type: "request", id, operation, params, ...(idempotencyKey ? { idempotency_key: idempotencyKey } : {}) });
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.socket.write(`${message}\n`);
    });
  }
  close(): void { this.closed = true; this.socket.destroy(); this.fail(new Error("Cloud relay closed")); }
  private receive(chunk: string): void {
    this.buffered += chunk;
    let newline;
    while ((newline = this.buffered.indexOf("\n")) >= 0) {
      const line = this.buffered.slice(0, newline); this.buffered = this.buffered.slice(newline + 1);
      try {
        const message = JSON.parse(line) as { id?: string; ok?: boolean; value?: CloudValue; error?: { message?: string } };
        if (!message.id) continue;
        const pending = this.pending.get(message.id); if (!pending) continue; this.pending.delete(message.id);
        if (message.ok) pending.resolve(message.value ?? null); else pending.reject(new Error(message.error?.message ?? "Cloud operation failed"));
      } catch { this.fail(new Error("Cloud relay returned invalid JSON")); }
    }
  }
  private fail(error: Error): void { for (const pending of this.pending.values()) pending.reject(error); this.pending.clear(); }
}

export function cloudTransportFromEnvironment(): UnixCloudTransport | undefined {
  const socket = process.env.CMUX_CLOUD_SOCKET;
  return socket ? new UnixCloudTransport(socket) : undefined;
}
