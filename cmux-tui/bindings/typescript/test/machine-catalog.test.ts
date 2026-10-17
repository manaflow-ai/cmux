import assert from "node:assert/strict";
import test from "node:test";
import { Client } from "../src/resources.js";
import type { Transport } from "../src/transport.js";

class CatalogTransport implements Transport {
  private message: (json: string) => void = () => {};
  constructor(private readonly value: unknown) {}
  send(json: string): void {
    const request = JSON.parse(json);
    assert.equal(request.operation, "machine.list");
    queueMicrotask(() => this.message(JSON.stringify({
      protocol: "cmux.protocol/2", type: "response", id: request.id, ok: true, result: [this.value],
    })));
  }
  onMessage(handler: (json: string) => void): () => void { this.message = handler; return () => {}; }
  onClose(): () => void { return () => {}; }
  onError(): () => void { return () => {}; }
  close(): void {}
}
const snapshot = (patch: object = {}) => ({
  id: "machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", name: "server", origin: "local",
  status: "running", connectable: true, deleted: false, recoverable: false, ...patch,
});
async function decode(value: unknown) {
  const client = new Client({ transport: new CatalogTransport(value) });
  try { return (await client.listMachines())[0]!.snapshot!; }
  finally { client.close(); }
}
test("machine catalog keeps each origin and owner metadata", async () => {
  for (const origin of ["local", "cloud", "ssh", "server"]) {
    const machine = await decode(snapshot({ origin, platform: { os: "linux", arch: "aarch64" }, capabilities: ["terminal", "agent_session"] }));
    assert.equal(machine.origin, origin);
    assert.equal(machine.platform?.os, "linux");
    assert.deepEqual(machine.capabilities, ["terminal", "agent_session"]);
  }
});
test("legacy machine catalogs remain usable with unknown metadata", async () => {
  const machine = await decode(snapshot());
  assert.equal(machine.origin, "local");
  assert.equal(machine.platform, undefined);
  assert.deepEqual(machine.capabilities, []);
  assert.equal((await decode(snapshot({ platform: { os: null } }))).platform?.os, null);
});
test("machine catalog metadata stays typed and unknown siblings are refused", async () => {
  for (const patch of [{ platform: 1 }, { platform: { os: 1 } }, { platform: { path: "/private" } },
    { capabilities: "terminal" }, { capabilities: null }, { capabilities: [1] }, { command: "echo bad" }]) {
    await assert.rejects(decode(snapshot(patch)));
  }
});
