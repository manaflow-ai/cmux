import test from "node:test";
import assert from "node:assert/strict";
import { createCloudBroker, serveCloudRelay } from "./cloud-relay.mjs";
import { createConnection } from "node:net";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
const relayCatalog = JSON.parse(readFileSync(fileURLToPath(new URL("../../../../backend/catalog/cloud-relay-operations.json", import.meta.url)), "utf8"));
const cloudCatalog = JSON.parse(readFileSync(fileURLToPath(new URL("../../../../backend/catalog/cloud-operations.json", import.meta.url)), "utf8"));

test("Cloud broker uses fixed VM routes and keeps bearer out of the request body", async () => {
  const calls = [];
  const broker = createCloudBroker({
    apiUrl: "https://cloud.test",
    bearerToken: "fixture-secret",
    catalog: relayCatalog,
    fetchImpl: async (url, init) => {
      calls.push({ url, init });
      return new Response(JSON.stringify({ id: "vm_fixture", status: "paused" }), { status: 200, headers: { "content-type": "application/json" } });
    },
  });
  const result = await broker.request("vm.resume", { vm_id: "vm_fixture" }, "resume-key");
  assert.deepEqual(result, { id: "vm_fixture", status: "paused" });
  assert.equal(calls[0].url, "https://cloud.test/api/vm/vm_fixture/resume");
  assert.equal(calls[0].init.method, "POST");
  assert.match(calls[0].init.headers.authorization, /^Bearer fixture-secret$/);
  assert.equal(calls[0].init.body, "{}");
  assert.equal(JSON.stringify(calls[0]), JSON.stringify(calls[0]).replace("fixture-secret", "fixture-secret"));
  assert.equal(calls[0].url.includes("fixture-secret"), false);
});

test("local fixture driver can exercise lifecycle without credentials or live machines", async () => {
  const broker = createCloudBroker({ catalog: relayCatalog, fixture: {
    "vm.list": [{ id: "vm_fixture", status: "running" }],
    "vm.pause": { id: "vm_fixture", status: "paused" },
    "vm.resume": { id: "vm_fixture", status: "running" },
  } });
  assert.deepEqual(await broker.request("vm.list", {}), [{ id: "vm_fixture", status: "running" }]);
  assert.deepEqual(await broker.request("vm.pause", { vm_id: "vm_fixture" }), { id: "vm_fixture", status: "paused" });
  assert.deepEqual(await broker.request("vm.resume", { vm_id: "vm_fixture" }), { id: "vm_fixture", status: "running" });
});

test("broker rejects unknown operations instead of accepting arbitrary URLs", async () => {
  const broker = createCloudBroker({ catalog: relayCatalog, fixture: {} });
  await assert.rejects(() => broker.request("http://attacker.test", {}), /not in the catalog/);
});

test("host allowlist does not inherit catalog operations marked deny", async () => {
  const merged = { operations: { ...relayCatalog.operations, ...cloudCatalog.operations } };
  const allowed = new Set(Object.keys(relayCatalog.operations));
  const broker = createCloudBroker({ catalog: merged, allowedOperations: allowed, fixture: { "vm.pause": { id: "vm_fixture", status: "paused" } } });
  await assert.rejects(() => broker.request("domain.list", {}), /not in the catalog/);
  assert.deepEqual(await broker.request("vm.pause", { vm_id: "vm_fixture" }), { id: "vm_fixture", status: "paused" });
});

test("catalog mutations use the protocol's script origin", async () => {
  const calls = [];
  const broker = createCloudBroker({
    catalog: relayCatalog,
    apiUrl: "https://cloud.test",
    bearerToken: "fixture-secret",
    fetchImpl: async (url, init) => {
      calls.push({ url, init });
      return new Response(JSON.stringify({ ok: true, value: { tunnelId: "tunnel_fixture" } }), { status: 200, headers: { "content-type": "application/json" } });
    },
  });
  await broker.request("tunnel.attach", { vm_id: "vm_fixture" }, "attach-key");
  const payload = JSON.parse(calls[0].init.body);
  assert.equal(payload.origin, "script");
  assert.equal(payload.idempotency_key, "attach-key");
});

test("domain and publication operations use fixed VM routes", async () => {
  const calls = [];
  const broker = createCloudBroker({
    catalog: relayCatalog,
    apiUrl: "https://cloud.test",
    bearerToken: "fixture-secret",
    fetchImpl: async (url, init) => {
      calls.push({ url, init });
      return new Response(JSON.stringify({ ok: true, publication: { id: "pub_fixture" } }), { status: 200 });
    },
  });
  await broker.request("vm.domain.verify", { name: "example.test" }, "domain-key");
  await broker.request("vm.publication.create", { vmId: "vm_fixture", port: 3000, accessMode: "personal" }, "publication-create-key");
  await broker.request("vm.publication.update", { id: "pub_fixture", accessMode: "personal" }, "publication-key");
  assert.equal(calls[0].url, "https://cloud.test/api/vm/domains/example.test/verify");
  assert.equal(calls[1].url, "https://cloud.test/api/vm/publications");
  assert.equal(calls[1].init.method, "POST");
  assert.deepEqual(JSON.parse(calls[1].init.body), { vmId: "vm_fixture", port: 3000, accessMode: "personal" });
  assert.equal(calls[2].url, "https://cloud.test/api/vm/publications/pub_fixture");
  assert.equal(calls[2].init.method, "PATCH");
  assert.deepEqual(JSON.parse(calls[2].init.body), { accessMode: "personal" });
});

test("host relay serves typed requests over a Unix socket", async () => {
  const dir = mkdtempSync(join(tmpdir(), "cmux-cloud-relay-"));
  const socketPath = join(dir, "relay.sock");
  const broker = createCloudBroker({ catalog: relayCatalog, fixture: { "vm.pause": { id: "vm_fixture", status: "paused" } } });
  const server = serveCloudRelay(socketPath, broker);
  try {
    await new Promise((resolve, reject) => {
      const timer = setInterval(() => {
        const socket = createConnection(socketPath);
        socket.setEncoding("utf8");
        socket.once("error", () => socket.destroy());
        socket.once("connect", () => {
          clearInterval(timer);
          socket.write(JSON.stringify({ protocol: "cmux.cloud/1", type: "request", id: "r1", operation: "vm.pause", params: { vm_id: "vm_fixture" } }) + "\n");
        });
        socket.once("data", (chunk) => {
          const response = JSON.parse(chunk);
          socket.destroy();
          assert.equal(response.id, "r1");
          assert.deepEqual(response.value, { id: "vm_fixture", status: "paused" });
          clearTimeout(timeout);
          resolve();
        });
      }, 5);
      const timeout = setTimeout(() => { clearInterval(timer); reject(new Error("relay did not start")); }, 1000);
    });
  } finally {
    server.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("snapshot restore posts the snapshot to the account restore route", async () => {
  const calls = [];
  const broker = createCloudBroker({
    apiUrl: "https://cloud.test",
    bearerToken: "fixture-secret",
    catalog: relayCatalog,
    fetchImpl: async (url, init) => {
      calls.push({ url, init });
      return new Response(JSON.stringify({ id: "vm_restored", status: "running" }), { status: 200, headers: { "content-type": "application/json" } });
    },
  });
  await broker.request("vm.snapshot.restore", { snapshot_id: "snap_fixture" }, "restore-key");
  assert.equal(calls[0].url, "https://cloud.test/api/vm/restore");
  assert.equal(calls[0].init.method, "POST");
  assert.deepEqual(JSON.parse(calls[0].init.body), { snapshot_id: "snap_fixture" });
  assert.equal(calls[0].init.headers["idempotency-key"], "restore-key");
});

test("every relay operation calls the method and path that its catalog binding declares", async () => {
  const params = { vm_id: "vm_x", snapshot_id: "snap_x", id: "pub_x", name: "example.com", path: "/tmp" };
  const values = { vm_id: "vm_x", snapshot_id: "snap_x", id: "pub_x", name: "example.com" };
  for (const [operation, entry] of Object.entries(relayCatalog.operations)) {
    const binding = entry.transport?.http;
    assert.ok(binding, `${operation} has an http binding`);
    const calls = [];
    const broker = createCloudBroker({
      apiUrl: "https://cloud.test",
      bearerToken: "fixture-secret",
      catalog: relayCatalog,
      fetchImpl: async (url, init) => {
        calls.push({ url, init });
        return new Response("{}", { status: 200, headers: { "content-type": "application/json" } });
      },
    });
    await broker.request(operation, { ...params }, entry.class === "mutation" ? `key-${operation}` : undefined);
    const expected = binding.path.replace(/:([a-z_]+)/g, (_, field) => encodeURIComponent(values[field]));
    const actual = new URL(calls[0].url);
    assert.equal(`${calls[0].init.method} ${actual.pathname}`, `${binding.method} ${expected}`, operation);
  }
});
