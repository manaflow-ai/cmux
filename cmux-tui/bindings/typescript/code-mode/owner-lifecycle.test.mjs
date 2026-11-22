import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { watchOwnerTurn } from "./owner-lifecycle.mjs";

const SESSION = "owner-session";
const TURN = "owner-turn";
const deferred = () => {
  let resolve;
  const promise = new Promise((done) => { resolve = done; });
  return { promise, resolve };
};
const event = (kind, msg, sessionId = SESSION) => ({
  jsonrpc: "2.0", method: "_acpmux/event", params: { sessionId, kind, msg },
});
const reply = (session = {}, events = []) => ({
  jsonrpc: "2.0", id: "code-mode-owner",
  result: { session: { sessionId: SESSION, status: "running", state: "running",
    turn: { turnId: TURN }, ...session }, events },
});

async function fixture(t) {
  const dir = await mkdtemp(join(tmpdir(), "cmux-owner-test-"));
  const path = join(dir, "owner.sock");
  const request = deferred();
  const sockets = new Set();
  const server = createServer((socket) => {
    sockets.add(socket);
    socket.on("error", () => {});
    let pending = "";
    socket.on("data", (data) => {
      pending += data.toString();
      const newline = pending.indexOf("\n");
      if (newline >= 0) request.resolve({ socket, message: JSON.parse(pending.slice(0, newline)) });
    });
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(path, resolve);
  });
  t.after(async () => {
    for (const socket of sockets) socket.destroy();
    await new Promise((resolve) => server.close(resolve));
    await rm(dir, { recursive: true, force: true });
  });
  return {
    env: { ACPMUX_SESSION_ID: SESSION, ACPMUX_SOCKET: path },
    request: request.promise,
  };
}

test("unowned CLI runs need no attachment; partial owner identity is refused", async () => {
  (await watchOwnerTurn({}, () => assert.fail("no owner")))();
  await assert.rejects(watchOwnerTurn({ ACPMUX_SESSION_ID: SESSION }, () => {}), /incomplete/);
  await assert.rejects(watchOwnerTurn({ ACPMUX_SOCKET: "/missing" }, () => {}), /incomplete/);
});

for (const kind of ["turn_end", "turn_error", "turn_result", "stopping"]) {
  test(`${kind} ends only the bound turn`, { timeout: 2_000 }, async (t) => {
    const f = await fixture(t);
    const ended = deferred();
    const watching = watchOwnerTurn(f.env, ended.resolve);
    const { socket, message } = await f.request;
    assert.equal(message.method, "_acpmux/attach");
    assert.equal(message.params.visible, false);
    assert.equal(message.params.eventStream, true);
    socket.write(`${JSON.stringify(reply())}\n`);
    const cleanup = await watching;
    t.after(cleanup);
    socket.write([
      event(kind, { turnId: "previous-turn" }),
      event(kind, { turnId: TURN }, "other-session"),
      event(kind, { turnId: TURN }),
    ].map(JSON.stringify).join("\n") + "\n");
    assert.equal(await ended.promise, `owner turn ${kind}`);
  });
}

test("an end before the attachment reply prevents starting", { timeout: 2_000 }, async (t) => {
  const f = await fixture(t);
  const ended = [];
  const watching = watchOwnerTurn(f.env, (why) => ended.push(why));
  const refused = assert.rejects(watching, /owner turn turn_end/);
  const { socket } = await f.request;
  socket.write([event("turn_end", { turnId: TURN }), reply()].map(JSON.stringify).join("\n") + "\n");
  await refused;
  assert.deepEqual(ended, ["owner turn turn_end"]);
});

test("a replayed owner end is not lost between snapshot and reply", { timeout: 2_000 }, async (t) => {
  const f = await fixture(t);
  const watching = watchOwnerTurn(f.env, () => {});
  const refused = assert.rejects(watching, /owner turn turn_result/);
  const { socket } = await f.request;
  socket.write(`${JSON.stringify(reply({}, [event("turn_result", { turnId: TURN }).params]))}\n`);
  await refused;
});

for (const owner of [{ turn: null }, { state: "stopping" }, { status: "closed" }]) {
  test(`inactive owner refuses launch: ${JSON.stringify(owner)}`, { timeout: 2_000 }, async (t) => {
    const f = await fixture(t);
    const watching = watchOwnerTurn(f.env, () => {});
    const refused = assert.rejects(watching, /no active turn/);
    const { socket } = await f.request;
    socket.write(`${JSON.stringify(reply(owner))}\n`);
    await refused;
  });
}

for (const stop of ["closed", "stopping", "purged", "lagged", "disconnect", "invalid"]) {
  test(`owner ${stop} terminates active scripts`, { timeout: 2_000 }, async (t) => {
    const f = await fixture(t);
    const ended = deferred();
    const watching = watchOwnerTurn(f.env, ended.resolve);
    const { socket } = await f.request;
    socket.write(`${JSON.stringify(reply())}\n`);
    t.after(await watching);
    if (stop === "disconnect") socket.end();
    else if (stop === "invalid") socket.write("invalid JSON\n");
    else socket.write(`${JSON.stringify(stop === "lagged"
      ? { jsonrpc: "2.0", method: "_acpmux/lagged" }
      : event(stop === "purged" ? "purged" : "status", { status: stop }))}\n`);
    assert.match(await ended.promise, /owner/);
  });
}

test("abort interrupts a pending attachment and closes its socket", { timeout: 2_000 }, async (t) => {
  const f = await fixture(t);
  const controller = new AbortController();
  const watching = watchOwnerTurn(f.env, () => {}, controller.signal);
  const refused = assert.rejects(watching, /aborted/);
  const { socket } = await f.request;
  const closed = new Promise((resolve) => socket.once("close", resolve));
  controller.abort();
  await refused;
  await closed;
});

test("cleanup removes the abort listener and closes without ending the owner", { timeout: 2_000 }, async (t) => {
  const f = await fixture(t);
  const controller = new AbortController();
  const ended = [];
  const watching = watchOwnerTurn(f.env, (why) => ended.push(why), controller.signal);
  const { socket } = await f.request;
  // Old closed/turn records must not affect a reopened, currently running owner.
  socket.write(`${JSON.stringify(reply({}, [event("status", { status: "closed" }).params,
    event("turn_end", { turnId: "old-turn" }).params]))}\n`);
  const cleanup = await watching;
  const closed = new Promise((resolve) => socket.once("close", resolve));
  cleanup();
  cleanup();
  controller.abort();
  await closed;
  assert.deepEqual(ended, []);
});
