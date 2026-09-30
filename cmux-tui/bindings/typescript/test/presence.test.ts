import assert from "node:assert/strict";
import test from "node:test";
import {
  decodeCommandResult,
  decodeProtocolEvent,
} from "../src/raw/protocol-codec.js";

test("command decoding distinguishes required nullable from omission", () => {
  assert.throws(
    () => decodeCommandResult("reload-config", { reloaded: true }),
    /reload-config result\.path is required/,
  );
  assert.deepEqual(
    decodeCommandResult("reload-config", { reloaded: true, path: null }),
    { reloaded: true, path: null },
  );
  assert.deepEqual(
    decodeCommandResult("reload-config", { reloaded: true, path: "/tmp/cmux.json" }),
    { reloaded: true, path: "/tmp/cmux.json" },
  );
});

test("command decoding enforces required non-null fields", () => {
  assert.throws(
    () => decodeCommandResult("ping", { ok: true, version: "0.1.2" }),
    /ping result\.protocol is required/,
  );
  assert.throws(
    () => decodeCommandResult("ping", {
      ok: true,
      version: "0.1.2",
      protocol: null,
    }),
    /ping result\.protocol must not be null/,
  );
  assert.deepEqual(
    decodeCommandResult("ping", {
      ok: true,
      version: "0.1.2",
      protocol: 10,
    }),
    { ok: true, version: "0.1.2", protocol: 10 },
  );
});

test("command decoding accepts all optional nullable states", () => {
  const base = { ok: true, version: "0.1.2", protocol: 10 };
  assert.deepEqual(decodeCommandResult("ping", base), base);
  assert.deepEqual(
    decodeCommandResult("ping", { ...base, build_commit: null }),
    { ...base, build_commit: null },
  );
  assert.deepEqual(
    decodeCommandResult("ping", { ...base, build_commit: "abc123" }),
    { ...base, build_commit: "abc123" },
  );
});

test("event decoding accepts optional non-null omission and value but rejects null", () => {
  assert.deepEqual(
    decodeProtocolEvent({ event: "title-changed", surface: 7n }),
    { event: "title-changed", surface: 7n },
  );
  assert.deepEqual(
    decodeProtocolEvent({ event: "title-changed", surface: 7n, title: "shell" }),
    { event: "title-changed", surface: 7n, title: "shell" },
  );
  assert.throws(
    () => decodeProtocolEvent({
      event: "title-changed",
      surface: 7n,
      title: null,
    }),
    /event title-changed\.title must not be null/,
  );
});

test("event decoding distinguishes required nullable from omission", () => {
  const notification = {
    event: "notification",
    notification: 1n,
    title: "Build",
    body: "Ready",
    level: "info",
  };
  assert.throws(
    () => decodeProtocolEvent(notification),
    /event notification\.surface is required/,
  );
  assert.deepEqual(
    decodeProtocolEvent({ ...notification, surface: null }),
    { ...notification, surface: null },
  );
  assert.deepEqual(
    decodeProtocolEvent({ ...notification, surface: 7n }),
    { ...notification, surface: 7n },
  );
});

test("nested command paths enforce required fields through arrays and refs", () => {
  const client = {
    client: 1n,
    transport: "ws",
    name: null,
    kind: null,
    connected_seconds: 2n,
    attached: [],
    sizes: [{ surface: 7n, cols: 80, rows: 24 }],
    self: true,
  };
  assert.throws(
    () => decodeCommandResult("list-clients", [client], { protocol: 10 }),
    /list-clients result\[0\]\.sizes\[0\]\.size_participating is required/,
  );
  assert.deepEqual(
    decodeCommandResult("list-clients", [client], { protocol: 9 }),
    [client],
  );
  assert.deepEqual(
    decodeCommandResult(
      "list-clients",
      [{
        ...client,
        sizes: [{ ...client.sizes[0], size_participating: true }],
      }],
      { protocol: 10 },
    ),
    [{
      ...client,
      sizes: [{ ...client.sizes[0], size_participating: true }],
    }],
  );
});

test("nested event paths enforce required fields through refs", () => {
  assert.throws(
    () => decodeProtocolEvent({
      event: "browser-state",
      surface: 7n,
      cols: 80,
      rows: 24,
      url: "https://example.com",
      title: "Example",
      status: "live",
      error: null,
      frames_stalled: false,
      frame: {
        seq: 1n,
        width: 800,
        height: 600,
      },
    }),
    /event browser-state\.frame\.data is required/,
  );
});

test("gated required nullable fields follow negotiated protocol context", () => {
  assert.deepEqual(
    decodeCommandResult("resize-surface", { accepted: true }, { protocol: 6 }),
    { accepted: true },
  );
  assert.throws(
    () => decodeCommandResult("resize-surface", { accepted: true }, { protocol: 7 }),
    /resize-surface result\.reservation_id is required/,
  );
  assert.deepEqual(
    decodeCommandResult(
      "resize-surface",
      { accepted: true, reservation_id: null },
      { protocol: 7 },
    ),
    { accepted: true, reservation_id: null },
  );
  assert.deepEqual(
    decodeCommandResult(
      "resize-surface",
      { accepted: true, reservation_id: 9 },
      { protocol: 7 },
    ),
    { accepted: true, reservation_id: 9n },
  );

  const resized = {
    event: "surface-resized",
    surface: 7n,
    cols: 80,
    rows: 24,
  };
  assert.deepEqual(
    decodeProtocolEvent(resized, { protocol: 6 }),
    resized,
  );
  assert.throws(
    () => decodeProtocolEvent(resized, { protocol: 7 }),
    /event surface-resized\.reservation_id is required/,
  );
  assert.deepEqual(
    decodeProtocolEvent({ ...resized, reservation_id: null }, { protocol: 7 }),
    { ...resized, reservation_id: null },
  );
  assert.deepEqual(
    decodeProtocolEvent({ ...resized, reservation_id: 11 }, { protocol: 7 }),
    { ...resized, reservation_id: 11n },
  );
});

test("identify infers its own protocol before validating gated required fields", () => {
  const legacy = {
    app: "cmux-tui",
    version: "0.1.2",
    protocol: 6,
    session: "main",
    pid: 1,
  };
  assert.deepEqual(decodeCommandResult("identify", legacy), legacy);
  assert.throws(
    () => decodeCommandResult("identify", { ...legacy, protocol: 7 }),
    /identify result\.(generation|registry_id|workspace_revision) is required/,
  );
  assert.throws(
    () => decodeCommandResult(
      "identify",
      { ...legacy, protocol: 10 },
      { protocol: 6 },
    ),
    /identify result\.(daemon_handoff|generation|registry_id|terminal_revision|workspace_revision) is required/,
  );
  const current = {
    ...legacy,
    protocol: 10,
    registry_id: "registry",
    generation: "generation",
    workspace_revision: 1,
    terminal_revision: 2,
    daemon_handoff: 1,
  };
  assert.deepEqual(
    decodeCommandResult("identify", current),
    {
      ...current,
      workspace_revision: 1n,
      terminal_revision: 2n,
    },
  );
});

test("unknown event names and serialized-only events stay raw", () => {
  const future = {
    event: "future-event",
    payload: { value: 9n },
  };
  assert.equal(decodeProtocolEvent(future), future);

  const serializedOnly = { event: "client-list-invalidated" };
  assert.equal(decodeProtocolEvent(serializedOnly), serializedOnly);

  assert.throws(
    () => decodeProtocolEvent({ event: "bell" }),
    /event bell\.surface is required/,
  );
});
