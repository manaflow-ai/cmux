import test from "node:test";
import assert from "node:assert/strict";
import { createCloudBroker, serveCloudRelay, OP_FIELDS, ACCEPTED, USER_ONLY, USER_ONLY_REFUSAL, classicAnswer, CLASSIC_MACHINE_FIELDS, CLASSIC_SIZE_FIELDS, CLASSIC_LIMITS_FIELDS, CLASSIC_UNSOURCED } from "./cloud-relay.mjs";
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
const ALIAS_OF = { "cloud.machine.list": "vm.list", "cloud.machine.get": "vm.get", "cloud.machine.rename": "vm.update",
  "cloud.machine.start": "vm.start", "cloud.machine.pause": "vm.pause", "cloud.snapshot.list": "vm.snapshot.list" };
// The Cloud app server's op table (first-party-apps/cloud/server/src/ops/mod.rs): which cloud.* ops only a person may send.
const SERVER_OPS = readFileSync(fileURLToPath(new URL("../../../../first-party-apps/cloud/server/src/ops/mod.rs", import.meta.url)), "utf8");
const userOnlyOps = new Set([...SERVER_OPS.matchAll(/\("(cloud\.[a-z_.]+)", Kind::UserOnly\)/g)].map((m) => m[1]));
const serverAliases = Object.fromEntries([...SERVER_OPS.matchAll(/\("(vm\.[a-z_.]+)", "(cloud\.[a-z_.]+)"\)/g)].map((m) => [m[1], m[2]]));
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
    ["vm.list", {}], ["vm.list", { cursor: "cur_page2", limit: 2 }], ["vm.get", { vm_id: "vm_x" }],
    ["vm.update", { vm_id: "vm_x", displayName: "renamed", expectedRevision: "12" }], ["vm.update", { vm_id: "vm_x", name: "n" }],
    ["vm.start", { vm_id: "vm_x" }], ["vm.resume", { vm_id: "vm_x", expected_revision: 3 }], ["vm.pause", { vm_id: "vm_x" }],
    ["vm.snapshot.list", { vm_id: "vm_x" }],
  ];
  for (const [operation, params] of cases) await broker.request(operation, params, `key-${operation}`);
  for (const [index, call] of calls.entries()) assert.deepEqual(envelopeProblems(call.body, call.url), [], JSON.stringify(cases[index]));
  const sent = (index) => calls[index].body;
  assert.deepEqual(sent(1).params, { cursor: "cur_page2", limit: 2 });
  assert.deepEqual(sent(3).params, { machine: "vm_x", name: "renamed" });
  assert.equal(sent(3).expected_revision, "12");
  assert.equal(sent(6).expected_revision, "3");
  assert.equal("expected_revision" in sent(0), false, "a read has no expected_revision");
});

// Every field each relay op's old classic /api/vm body took (the relay passed params through before this
// change; the shapes are the deleted callers': CloudAPIClient.swift's createMachine, renameMachine, resize,
// snapshot and restore, and cmux-cloud-api classic.rs's vm.resize pick of cpu, memoryMb and storageMb), and
// the protocol field it is now. null: refused loudly, with why.
const OLD_SURFACE = {
  "vm.update": { displayName: ["name", "renamed"], name: ["name", "renamed"] },
  "vm.list": { cursor: ["cursor", "c"], limit: ["limit", 2] },
};
const ID = { "vm.list": {} };

test("every field a relay op took before cmux-platform maps onto a protocol field or is refused, never dropped", async () => {
  for (const [operation, fields] of Object.entries(OLD_SURFACE)) {
    for (const [field, [target, value]] of Object.entries(fields)) {
      const { broker, calls } = recordingBroker();
      const base = ID[operation] ?? { vm_id: "vm_x" };
      const outcome = await broker.request(operation, { ...base, [field]: value }, "k").then(() => null, (error) => error);
      if (target === null) {
        assert.ok(outcome, `${operation}.${field} is refused`);
        assert.equal(calls.length, 0, `${operation}.${field}: nothing sent`);
        continue;
      }
      assert.equal(outcome, null, `${operation}.${field}: ${outcome?.message}`);
      const [head, tail] = target.split(".");
      const sent = tail ? calls[0].body.params[head]?.[tail] : calls[0].body.params[head];
      assert.deepEqual(sent, value, `${operation}.${field} -> ${target}`);
      assert.deepEqual(envelopeProblems(calls[0].body, calls[0].url), [], `${operation}.${field}`);
    }
  }
  // Every old field is in its op's accepted list (or refused by name), so none can fall through unlisted.
  for (const [operation, fields] of Object.entries(OLD_SURFACE)) {
    for (const [field, [target]] of Object.entries(fields)) if (target !== null) assert.ok(ACCEPTED[operation].includes(field), `${operation}.${field}`);
  }
});

test("a field an aliased relay op does not take is refused before any request", async () => {
  const { broker, calls } = recordingBroker();
  await assert.rejects(broker.request("vm.update", { vm_id: "vm_x", name: "n", stray: 1 }, "k"), /takes no stray/);
  await assert.rejects(broker.request("vm.get", { vm_id: "vm_x", storageMb: 1 }, "k"), /takes no storageMb/);
  await assert.rejects(broker.request("vm.update", { vm_id: "vm_x", displayName: null }, "k"), /needs a name/);
  assert.equal(calls.length, 0);
});

test("the relay offers no op cmux-platform takes only from a person, and offers every other relay alias", () => {
  for (const [relayOp, op] of Object.entries(serverAliases)) {
    const offered = Object.hasOwn(relayCatalog.operations, relayOp);
    if (userOnlyOps.has(op)) {
      assert.equal(offered, false, `${relayOp} (${op}) is user-only and must not be offered`);
      assert.ok(USER_ONLY.has(relayOp), `${relayOp} is refused by name`);
    } else assert.ok(offered, `${relayOp} (${op}) stays offered`);
  }
  assert.ok(userOnlyOps.has("cloud.machine.create") && userOnlyOps.has("cloud.snapshot.delete"), "the server's table was read");
  for (const relayOp of USER_ONLY) assert.ok(userOnlyOps.has(serverAliases[relayOp]), `${relayOp} is user-only on the server`);
});

test("a user-only machine change from a script fails at once with the reason, and sends nothing", async () => {
  const { broker, calls } = recordingBroker();
  const fixture = createCloudBroker({ catalog: relayCatalog, fixture: { "vm.create": { id: "vm_fake" } } });
  for (const operation of USER_ONLY) {
    await assert.rejects(broker.request(operation, { vm_id: "vm_x", snapshot_id: "snap_x" }, "k"), (error) => error.message === USER_ONLY_REFUSAL, operation);
    await assert.rejects(fixture.request(operation, { vm_id: "vm_x" }, "k"), /need you in the app/, operation);
  }
  assert.equal(calls.length, 0);
  assert.match(USER_ONLY_REFUSAL, /need you in the app; scripts can't/);
});

test("every checked-in protocol vector of an aliased op: the relay sends the vector's params and reads its answer", async () => {
  const cases = vectors.cases.filter((c) => Object.hasOwn(ALIAS_OF, c.op) && c.responses?.[0]?.http?.status);
  assert.ok(cases.length >= 10, `vectors found: ${cases.length}`);
  assert.ok(cases.some((c) => c.name === "machine.start.quota"), "an ok:false mutation vector is replayed");
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
      assert.deepEqual(outcome.value, classicAnswer(vector.op, body.value ?? body), vector.name);
    } else {
      refusals += 1;
      assert.ok(outcome.error, `${vector.name}: a refusal resolved as ${JSON.stringify(outcome.value)}`);
      const message = body?.error?.message ?? body?.message;
      if (message) assert.equal(outcome.error.message, message, vector.name);
    }
  }
  assert.ok(refusals > 0, "the vectors include refusals");
});

// The answer each relay op gave before cmux-platform: classic /api/vm's machine record (the fields
// cmux-cloud-machine record.rs `from_classic` read), `{vms, limits}` for a list, `{snapshots}` of
// `{id or snapshotId, name}` (models.rs `snapshot`). The old answers of rename, start, resume and pause
// went unread by every caller; the relay gives them the machine record.
const OLD_ANSWER = {
  "vm.list": "list", "vm.get": "machine", "vm.update": "machine", "vm.start": "machine", "vm.resume": "machine",
  "vm.pause": "machine", "vm.snapshot.list": "snapshots",
};
function oldShapeProblems(kind, value, at) {
  const problems = [];
  const missing = (object, fields, where) => { for (const field of fields) if (!(object && typeof object === "object" && field in object)) problems.push(`${where}.${field}: missing`); };
  const machine = (record, where) => {
    missing(record, CLASSIC_MACHINE_FIELDS, where);
    missing(record?.size, CLASSIC_SIZE_FIELDS, `${where}.size`);
    for (const field of ["id", "status"]) if (typeof record?.[field] !== "string") problems.push(`${where}.${field}: not a string`);
    if (record?.image !== null && typeof record?.image !== "string") problems.push(`${where}.image: not the classic image name`);
  };
  if (kind === "list") {
    if (!Array.isArray(value?.vms)) problems.push(`${at}.vms: not a list`); else value.vms.forEach((record, i) => machine(record, `${at}.vms[${i}]`));
    missing(value?.limits, CLASSIC_LIMITS_FIELDS, `${at}.limits`);
  } else if (kind === "snapshots") {
    if (!Array.isArray(value?.snapshots)) problems.push(`${at}.snapshots: not a list`);
    else value.snapshots.forEach((snap, i) => { if (typeof (snap?.snapshotId ?? snap?.id) !== "string") problems.push(`${at}.snapshots[${i}]: no id`); missing(snap, ["name"], `${at}.snapshots[${i}]`); });
  } else machine(value, at);
  return problems;
}
/** Every platform field of `platform` that `value` dropped (classic's `image` is a name string, so the
 * platform's image object rides as `image_ref`). */
function droppedProblems(platform, value, at) {
  if (!platform || typeof platform !== "object" || Array.isArray(platform)) return [];
  const problems = [];
  for (const [field, inner] of Object.entries(platform)) {
    const kept = field === "image" && value && "image_ref" in value ? value.image_ref : value?.[field];
    if (kept === undefined) problems.push(`${at}.${field}: dropped`);
    else if (Array.isArray(inner)) inner.forEach((item, i) => problems.push(...droppedProblems(item, kept[i], `${at}.${field}[${i}]`)));
    else if (field !== "image") problems.push(...droppedProblems(inner, kept, `${at}.${field}`));
  }
  return problems;
}

test("every relay op answers with every field its pre-platform answer had, and keeps the platform's own", async () => {
  assert.deepEqual(Object.keys(OLD_ANSWER).sort(), Object.keys(ACCEPTED).sort(), "every served alias has an old answer shape");
  let checked = 0;
  for (const [operation, kind] of Object.entries(OLD_ANSWER)) {
    const op = serverAliases[operation] ?? relayAlias(operation);
    const cases = vectors.cases.filter((c) => c.op === op && c.responses?.[0]?.http?.status === 200 && c.responses[0].body?.ok !== false);
    assert.ok(cases.length > 0, `${operation}: no success vector of ${op}`);
    for (const vector of cases) {
      const body = vector.responses[0].body;
      const { broker } = recordingBroker(() => new Response(JSON.stringify(body), { status: 200 }));
      const params = vector.params.machine ? { vm_id: vector.params.machine } : {};
      if (operation === "vm.update") params.name = vector.params.name ?? "renamed";
      const value = await broker.request(operation, params, vector.idempotency_key);
      assert.deepEqual(oldShapeProblems(kind, value, `${operation}<${vector.name}>`), []);
      const platform = body.value ?? body;
      const flat = kind === "machine" && platform.machine ? platform.machine : platform;
      assert.deepEqual(droppedProblems(flat, value, `${operation}<${vector.name}>`), []);
      checked += 1;
    }
  }
  assert.ok(checked >= Object.keys(OLD_ANSWER).length);
});
function relayAlias(operation) { return { "vm.list": "cloud.machine.list", "vm.get": "cloud.machine.get", "vm.update": "cloud.machine.rename", "vm.start": "cloud.machine.start", "vm.resume": "cloud.machine.start", "vm.pause": "cloud.machine.pause", "vm.snapshot.list": "cloud.snapshot.list" }[operation]; }

test("the classic fields this Cloud has no source for are present as null, and named", async () => {
  const machine = { id: "vm_x", team: "t", creator: "u", name: "box", size: { cpu: 2, memory_mb: 4096, disk_mb: 16384 }, status: "running", image: { id: "img", daemon_version: "1" }, created_at: 1, idle_policy: { idle_seconds: 1800 } };
  const listed = classicAnswer("cloud.machine.list", { machines: [machine, { ...machine, id: "vm_y", status: "paused" }], next_cursor: null, revision: "4" });
  const record = listed.vms[0];
  for (const path of CLASSIC_UNSOURCED) {
    const [head, tail] = path.split(".");
    const holder = head === "limits" ? listed.limits : tail ? record[head] : record;
    const field = head === "limits" || tail ? tail : head;
    assert.ok(field in holder, `${path}: missing`);
    assert.ok(holder[field] === null || (Array.isArray(holder[field]) && holder[field].length === 0) || (typeof holder[field] === "object" && Object.keys(holder[field]).length === 0), `${path}: invented ${JSON.stringify(holder[field])}`);
  }
  assert.deepEqual({ displayName: record.displayName, image: record.image, imageVersion: record.imageVersion, createdAt: record.createdAt, createdByUserId: record.createdByUserId, idlePauseMinutes: record.idlePauseMinutes },
    { displayName: "box", image: "img", imageVersion: "1", createdAt: 1, createdByUserId: "u", idlePauseMinutes: 30 });
  assert.deepEqual(record.size, { cpu: 2, memory_mb: 4096, disk_mb: 16384, name: null, memoryMb: 4096, storageMb: 16384 });
  assert.equal(listed.limits.activeVmCount, 1);
  assert.equal(listed.next_cursor, null);
  assert.equal(listed.revision, "4");
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
    // An aliased op takes only its own fields (ACCEPTED); the rest take the shared set.
    const own = ACCEPTED[operation] ? Object.fromEntries(Object.entries(params).filter(([field]) => ACCEPTED[operation].includes(field))) : params;
    await broker.request(operation, { ...own }, entry.class === "mutation" ? `key-${operation}` : undefined);
    const expected = binding.path.replace(/:([a-z_]+)/g, (_, field) => encodeURIComponent(values[field]));
    const actual = new URL(calls[0].url);
    assert.equal(`${calls[0].init.method} ${actual.pathname}`, `${binding.method} ${expected}`, operation);
  }
});
