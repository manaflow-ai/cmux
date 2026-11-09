import test from "node:test";
import assert from "node:assert/strict";
import { createCloudBroker, serveCloudRelay, OP_FIELDS } from "./cloud-relay.mjs";
import { createConnection } from "node:net";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
const relayCatalog = JSON.parse(readFileSync(fileURLToPath(new URL("../../../../backend/catalog/cloud-relay-operations.json", import.meta.url)), "utf8"));
const cloudCatalog = JSON.parse(readFileSync(fileURLToPath(new URL("../../../../backend/catalog/cloud-operations.json", import.meta.url)), "utf8"));

test("Cloud broker sends machine ops to cmux-platform's cloud.* ops and keeps bearer out of the request body", async () => {
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
  assert.equal(calls[0].url, "https://cloud.test/v1/ops");
  assert.equal(calls[0].init.method, "POST");
  assert.match(calls[0].init.headers.authorization, /^Bearer fixture-secret$/);
  assert.deepEqual(JSON.parse(calls[0].init.body), { op: "cloud.machine.start", params: { machine: "vm_fixture" }, idempotency_key: "resume-key", origin: "script" });
  assert.equal(calls[0].init.body.includes("fixture-secret"), false);
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

test("a machine's exec and file ops go to cmux-platform's machine routes", async () => {
  const calls = [];
  const broker = createCloudBroker({
    catalog: relayCatalog,
    apiUrl: "https://cloud.test",
    bearerToken: "fixture-secret",
    fetchImpl: async (url, init) => {
      calls.push({ url, init });
      return new Response(JSON.stringify({ exitCode: 0 }), { status: 200 });
    },
  });
  await broker.request("vm.exec", { vm_id: "vm_fixture", command: "true", timeoutMs: 1000 }, "exec-key");
  await broker.request("vm.fs.read", { vm_id: "vm_fixture", path: "/a b" });
  assert.deepEqual(calls.map((call) => [call.init.method, call.url]), [
    ["POST", "https://cloud.test/v1/cloud/machines/vm_fixture/exec"],
    ["GET", "https://cloud.test/v1/cloud/machines/vm_fixture/fs/read?path=%2Fa%20b"],
  ]);
  assert.deepEqual(JSON.parse(calls[0].init.body), { command: "true", timeoutMs: 1000 });
  await assert.rejects(broker.request("vm.fs.read", { vm_id: "vm_fixture", path: "/a/../b" }), /without '\.\.'/);
});

// ---- the relay against cmux-platform's protocol: backend/catalog/cloud-operations.json and cloud-vectors.json ----
const vectors = JSON.parse(readFileSync(fileURLToPath(new URL("../../../../backend/catalog/cloud-vectors.json", import.meta.url)), "utf8"));
const ALIAS_OF = { "cloud.machine.list": "vm.list", "cloud.machine.get": "vm.get", "cloud.machine.create": "vm.create",
  "cloud.machine.rename": "vm.update", "cloud.machine.start": "vm.start", "cloud.machine.pause": "vm.pause",
  "cloud.machine.resize": "vm.resize", "cloud.machine.delete": "vm.delete", "cloud.snapshot.list": "vm.snapshot.list",
  "cloud.snapshot.create": "vm.snapshot.create", "cloud.snapshot.restore": "vm.snapshot.restore", "cloud.snapshot.delete": "vm.snapshot.delete" };
const ENVELOPE = { mutation: ["op", "params", "idempotency_key", "origin", "expected_revision"], read: ["op", "params"] };

/** Every problem of `value` against catalog type `type` (cloud-operations.json's type language). */
function typeProblems(value, type, at) {
  if (type.kind === "ref") {
    const named = cloudCatalog.types?.[type.name];
    return named ? typeProblems(value, named, at) : (typeof value === "string" ? [] : [`${at}: ${type.name} is not a string`]);
  }
  if (type.kind === "nullable") return value === null ? [] : typeProblems(value, type.inner, at);
  if (type.kind === "primitive") {
    if (type.name === "string" || type.name === "decimal") return typeof value === "string" && value.length >= (type.min_length ?? 0) && value.length <= (type.max_length ?? Infinity) ? [] : [`${at}: not a ${type.name}`];
    if (type.name === "int64") return Number.isInteger(value) ? [] : [`${at}: not an int64`];
    if (type.name === "bool" || type.name === "boolean") return typeof value === "boolean" ? [] : [`${at}: not a boolean`];
    return [];
  }
  if (type.kind === "object") return fieldsProblems(value, type.fields ?? {}, at, type.extra === true);
  return [];
}
function fieldsProblems(value, fields, at, extra = false) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return [`${at}: not an object`];
  const problems = [];
  for (const [field, spec] of Object.entries(fields)) {
    if (spec.required && !(field in value)) problems.push(`${at}.${field}: required`);
    else if (field in value) problems.push(...typeProblems(value[field], spec.type, `${at}.${field}`));
  }
  if (!extra) for (const field of Object.keys(value)) if (!(field in fields)) problems.push(`${at}.${field}: not a field`);
  return problems;
}
/** The envelope's problems: its route and fields, its params against the op's contract, and an empty size. */
function envelopeProblems(sent, url) {
  const contract = cloudCatalog.operations[sent.op];
  if (!contract) return [`${sent.op}: no contract`];
  const problems = [];
  const path = new URL(url).pathname;
  if (path !== (contract.class === "mutation" ? "/v1/ops" : "/v1/read")) problems.push(`${sent.op}: sent to ${path}`);
  for (const field of Object.keys(sent)) if (!ENVELOPE[contract.class].includes(field)) problems.push(`${sent.op}: envelope has ${field}`);
  if (contract.class === "mutation") {
    if (typeof sent.idempotency_key !== "string" || !sent.idempotency_key) problems.push(`${sent.op}: no idempotency_key`);
    if (sent.origin !== "script") problems.push(`${sent.op}: origin ${sent.origin}`);
    if ("expected_revision" in sent && typeof sent.expected_revision !== "string") problems.push(`${sent.op}: expected_revision is not a decimal string`);
  }
  const fields = { ...contract.params.fields };
  delete fields.expected_revision; // an envelope field (cmux-platform OpRequest), never a param
  problems.push(...fieldsProblems(sent.params, fields, sent.op, contract.params.extra === true));
  if (sent.params.size && Object.keys(sent.params.size).length === 0) problems.push(`${sent.op}: an empty size`);
  return problems;
}
function recordingBroker(answer = () => new Response("{}", { status: 200 })) {
  const calls = [];
  const broker = createCloudBroker({ catalog: relayCatalog, apiUrl: "https://cloud.test", bearerToken: "fixture-secret",
    fetchImpl: async (url, init) => { calls.push({ url, init, body: init.body === undefined ? undefined : JSON.parse(init.body) }); return answer(); } });
  return { broker, calls };
}

test("OP_FIELDS is each aliased op's params contract, without the envelope's expected_revision", () => {
  for (const [op, fields] of Object.entries(OP_FIELDS)) {
    const contract = Object.keys(cloudCatalog.operations[op].params.fields).filter((f) => f !== "expected_revision");
    assert.deepEqual([...fields].sort(), contract.sort(), op);
  }
  assert.deepEqual(Object.keys(OP_FIELDS).sort(), Object.keys(ALIAS_OF).sort());
});

test("every aliased relay op sends a valid /v1/ops or /v1/read envelope, whatever spelling it is given", async () => {
  const { broker, calls } = recordingBroker();
  const cases = [
    ["vm.list", {}], ["vm.list", { cursor: "cur_page2", limit: 2 }],
    ["vm.get", { vm_id: "vm_x" }],
    ["vm.create", {}], ["vm.create", { name: "box" }], ["vm.create", { displayName: "box", cpu: 4, memoryMb: 8192, diskMb: 32768 }],
    ["vm.create", { name: "box", size: { memory_mb: 8192 }, image: "img_x", snapshot_id: "snap_x", expected_revision: 7 }],
    ["vm.update", { vm_id: "vm_x", displayName: "renamed", expectedRevision: "12" }], ["vm.update", { vm_id: "vm_x", name: "n", stray: 1 }],
    ["vm.start", { vm_id: "vm_x" }], ["vm.resume", { vm_id: "vm_x", expected_revision: "3" }], ["vm.pause", { vm_id: "vm_x" }],
    ["vm.resize", { vm_id: "vm_x", memoryMb: 8192 }], ["vm.resize", { vm_id: "vm_x", size: { cpu: 2 }, expected_revision: "4" }],
    ["vm.delete", { vm_id: "vm_x" }], ["vm.snapshot.list", { vm_id: "vm_x" }], ["vm.snapshot.create", { vm_id: "vm_x", name: "s" }],
    ["vm.snapshot.restore", { vm_id: "vm_x", snapshot_id: "snap_x", name: "back" }], ["vm.snapshot.delete", { vm_id: "vm_x", snapshot_id: "snap_x" }],
  ];
  for (const [operation, params] of cases) await broker.request(operation, params, `key-${operation}`);
  for (const [index, call] of calls.entries()) assert.deepEqual(envelopeProblems(call.body, call.url), [], JSON.stringify(cases[index]));
  const sent = (index) => calls[index].body;
  assert.deepEqual(sent(1).params, { cursor: "cur_page2", limit: 2 });
  assert.deepEqual(sent(3).params, { size: { cpu: 2, disk_mb: 16384 } }, "a create with no size gets the platform's default, never {}");
  assert.deepEqual(sent(4).params, { name: "box", size: { cpu: 2, disk_mb: 16384 } });
  assert.deepEqual(sent(5).params, { name: "box", size: { cpu: 4, memory_mb: 8192, disk_mb: 32768 } });
  assert.deepEqual(sent(6).params, { name: "box", size: { memory_mb: 8192 }, image: "img_x", from_snapshot: "snap_x" });
  assert.equal(sent(6).expected_revision, "7");
  assert.deepEqual(sent(7).params, { machine: "vm_x", name: "renamed" });
  assert.equal(sent(7).expected_revision, "12");
  assert.deepEqual(sent(8).params, { machine: "vm_x", name: "n" });
  assert.equal(sent(10).expected_revision, "3");
  assert.deepEqual(sent(12).params, { machine: "vm_x", size: { memory_mb: 8192 } });
  assert.equal(sent(13).expected_revision, "4");
  assert.deepEqual(sent(17).params, { snapshot: "snap_x", name: "back" });
  assert.equal("expected_revision" in sent(0), false, "a read has no expected_revision");
});

test("a resize that names no size sends none, so the platform refuses it instead of an empty one", async () => {
  const { broker, calls } = recordingBroker();
  await broker.request("vm.resize", { vm_id: "vm_x" }, "k");
  assert.deepEqual(calls[0].body.params, { machine: "vm_x" });
});

test("every checked-in protocol vector of an aliased op: the relay sends the vector's params and reads its answer", async () => {
  const cases = vectors.cases.filter((c) => Object.hasOwn(ALIAS_OF, c.op) && c.responses?.[0]?.http?.status);
  assert.ok(cases.length >= 10, `vectors found: ${cases.length}`);
  assert.ok(cases.some((c) => c.name === "machine.create.quota"));
  let refusals = 0;
  for (const vector of cases) {
    const response = vector.responses[0];
    const { broker, calls } = recordingBroker(() => new Response(JSON.stringify(response.body), { status: response.http.status }));
    const relayParams = {};
    for (const [field, value] of Object.entries(vector.params)) relayParams[field === "machine" ? "vm_id" : field === "snapshot" ? "snapshot_id" : field] = value;
    const outcome = await broker.request(ALIAS_OF[vector.op], relayParams, vector.idempotency_key).then((value) => ({ value }), (error) => ({ error }));
    const sent = calls[0].body;
    assert.equal(sent.op, vector.op, vector.name);
    assert.deepEqual(sent.params, vector.params, `${vector.name}: the params the platform's vector sends`);
    assert.deepEqual(envelopeProblems(sent, calls[0].url), [], vector.name);
    assert.equal(new URL(calls[0].url).pathname, response.http.path, vector.name);
    if (vector.idempotency_key) assert.equal(sent.idempotency_key, vector.idempotency_key, vector.name);
    const body = response.body;
    if (response.http.status >= 200 && response.http.status < 300 && body?.ok !== false) {
      assert.ok(!outcome.error, `${vector.name}: ${outcome.error?.message}`);
      assert.deepEqual(outcome.value, body.value ?? body, vector.name);
    } else {
      refusals += 1;
      assert.ok(outcome.error, `${vector.name}: a refusal resolved as ${JSON.stringify(outcome.value)}`);
      const message = body?.error?.message ?? body?.message;
      if (message) assert.equal(outcome.error.message, message, vector.name);
    }
  }
  assert.ok(refusals > 0, "the vectors include refusals");
});

test("a machine's exec and file ops send the bodies cmux-platform's guest routes take", async () => {
  const { broker, calls } = recordingBroker();
  const GUEST = /^\/v1\/cloud\/machines\/vm_x\/(exec|fs\/(?:dir|read|stat|write|mkdir|remove))$/;
  const BODY = { exec: ["command", "stdinBase64", "timeoutMs"], "fs/write": ["path", "dataBase64", "mode"], "fs/mkdir": ["path"] };
  await broker.request("vm.exec", { vm_id: "vm_x", command: "true", timeoutMs: 1000 }, "k1");
  await broker.request("vm.fs.write", { vm_id: "vm_x", path: "/a", dataBase64: "aGk=", mode: 420 }, "k2");
  await broker.request("vm.fs.mkdir", { vm_id: "vm_x", path: "/d" }, "k3");
  for (const operation of ["vm.fs.list", "vm.fs.read", "vm.fs.stat", "vm.fs.remove"]) await broker.request(operation, { vm_id: "vm_x", path: "/a" }, "k");
  for (const call of calls) {
    const url = new URL(call.url);
    const route = url.pathname.match(GUEST)?.[1];
    assert.ok(route, url.pathname);
    if (BODY[route]) for (const field of Object.keys(call.body)) assert.ok(BODY[route].includes(field), `${route} takes no ${field}`);
    else { assert.equal(call.body, undefined, route); assert.equal(url.searchParams.get("path"), "/a", route); }
  }
});

test("classic publication, domain and API key ops are gone from the relay", async () => {
  const broker = createCloudBroker({ catalog: relayCatalog, apiUrl: "https://cloud.test", bearerToken: "fixture-secret", fetchImpl: async () => { throw new Error("no request"); } });
  for (const operation of ["vm.domain.list", "vm.publication.create", "vm.api.provision", "vm.publication.api-key.revoke"]) {
    await assert.rejects(broker.request(operation, {}), /not in the catalog/);
  }
  for (const [operation, entry] of Object.entries(relayCatalog.operations)) {
    assert.equal(entry.transport.http.path.includes("/api/vm"), false, operation);
  }
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

test("snapshot restore sends cloud.snapshot.restore with only the snapshot", async () => {
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
  assert.equal(calls[0].url, "https://cloud.test/v1/ops");
  assert.equal(calls[0].init.method, "POST");
  assert.deepEqual(JSON.parse(calls[0].init.body), { op: "cloud.snapshot.restore", params: { snapshot: "snap_fixture" }, idempotency_key: "restore-key", origin: "script" });
  assert.equal(calls[0].init.headers["idempotency-key"], "restore-key");
});

test("snapshot create generates an idempotency key when code mode omits one", async () => {
  const calls = [];
  const broker = createCloudBroker({
    apiUrl: "https://cloud.test",
    bearerToken: "fixture-secret",
    catalog: relayCatalog,
    fetchImpl: async (url, init) => {
      calls.push({ url, init });
      return new Response(JSON.stringify({ id: "snap_created" }), { status: 200, headers: { "content-type": "application/json" } });
    },
  });

  await broker.request("vm.snapshot.create", { vm_id: "vm_fixture", name: "before-upgrade" });

  assert.equal(calls[0].url, "https://cloud.test/v1/ops");
  assert.equal(calls[0].init.method, "POST");
  assert.match(calls[0].init.headers["idempotency-key"], /^[0-9a-f-]{36}$/);
  const body = JSON.parse(calls[0].init.body);
  assert.equal(body.op, "cloud.snapshot.create");
  assert.deepEqual(body.params, { machine: "vm_fixture", name: "before-upgrade" });
  assert.equal(body.idempotency_key, calls[0].init.headers["idempotency-key"]);
});

test("every relay operation calls the method and path that its catalog binding declares", async () => {
  const params = { vm_id: "vm_x", snapshot_id: "snap_x", id: "pub_x", key_id: "key_x", name: "example.com", path: "/tmp" };
  const values = { vm_id: "vm_x", snapshot_id: "snap_x", id: "pub_x", key_id: "key_x", name: "example.com" };
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
