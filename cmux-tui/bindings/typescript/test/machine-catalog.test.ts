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


test("cmux_next_machine_sdk_catalog_opt_in keeps defaults and the captured owner", async () => {
  const seen: Array<Record<string, any>> = [];
  let receive: (json: string) => void = () => {};
  const transport: Transport = {
    send(json) {
      const request = JSON.parse(json);
      seen.push(request);
      const value = snapshot(request.params.catalog === true ? { platform: { os: "linux" }, capabilities: ["terminal"] } : {});
      queueMicrotask(() => receive(JSON.stringify({ protocol: "cmux.protocol/2", type: "response", id: request.id,
        ok: true, result: request.operation === "machine.list" ? [value] : value })));
    },
    onMessage(handler) { receive = handler; return () => {}; },
    onClose() { return () => {}; }, onError() { return () => {}; }, close() {},
  };
  const client = new Client({ transport });
  try {
    const owner = (await client.listMachines())[0]!;
    await client.listMachines({ catalog: true });
    await client.listMachines({ catalog: false });
    for (const catalog of [1, "true", null]) {
      await assert.rejects(client.listMachines({ catalog: catalog as unknown as boolean }), TypeError);
      assert.throws(() => owner.refresh({ catalog: catalog as unknown as boolean }), TypeError);
    }
    await owner.refresh();
    const rich = await owner.refresh({ catalog: true });
    await owner.refresh({ catalog: false });
    assert.equal(seen.length, 6);
    seen.forEach((request, index) => {
      const expected: Record<string, unknown> = index < 3 ? {} : { machine: snapshot().id };
      if (index === 1 || index === 4) expected.catalog = true;
      assert.deepEqual(request.params, expected, `wire request ${index}`);
      assert.equal(request.idempotency_key, undefined);
    });
    assert.equal(rich.platform?.os, "linux");
  } finally { client.close(); }
});
