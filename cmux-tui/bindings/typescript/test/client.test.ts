import assert from "node:assert/strict";
import test from "node:test";
import { CmuxClient, CmuxStream } from "../src/client.js";
import { CmuxCommandError, CmuxProtocolError } from "../src/errors.js";
import type { DecodedResizedEvent, TreeDeltaEvent } from "../src/protocol/index.js";
import type { Transport, Unsubscribe } from "../src/transport.js";

class ScriptedTransport implements Transport {
  private readonly messageHandlers = new Set<(json: string) => void>();
  private readonly closeHandlers = new Set<() => void>();
  private readonly errorHandlers = new Set<(error: Error) => void>();
  constructor(private readonly script: (request: Record<string, unknown>, transport: ScriptedTransport) => void) {}
  send(json: string): void { this.script(JSON.parse(json) as Record<string, unknown>, this); }
  onMessage(handler: (json: string) => void): Unsubscribe { this.messageHandlers.add(handler); return () => this.messageHandlers.delete(handler); }
  onClose(handler: () => void): Unsubscribe { this.closeHandlers.add(handler); return () => this.closeHandlers.delete(handler); }
  onError(handler: (error: Error) => void): Unsubscribe { this.errorHandlers.add(handler); return () => this.errorHandlers.delete(handler); }
  close(): void { for (const handler of this.closeHandlers) handler(); }
  emit(value: Record<string, unknown>): void {
    const json = JSON.stringify(value);
    for (const handler of this.messageHandlers) handler(json);
  }
}

test("stream fails closed at the default buffered-event cap", async () => {
  let cleanups = 0;
  const stream = new CmuxStream<{ event: string }>(100, () => { cleanups += 1; });

  for (let index = 0; index <= 256; index += 1) {
    stream.push({ event: `event-${index}` });
  }

  await assert.rejects(() => stream.next(), /stream event buffer overflow/);
  assert.equal(cleanups, 1);
});

test("async iteration reports buffered-event overflow before the first pull", async () => {
  const stream = new CmuxStream<{ event: string }>(100, () => undefined, 1);
  stream.push({ event: "first" });
  stream.push({ event: "overflow" });

  const iterator = stream[Symbol.asyncIterator]();
  await assert.rejects(() => iterator.next(), /stream event buffer overflow/);
});

test("attachSurface rejects oversized encoded data before decoding", async () => {
  const main = new ScriptedTransport((request, transport) => {
    transport.emit({
      id: request.id,
      ok: true,
      data: { app: "cmux-tui", version: "0.1.2", protocol: 6, session: "main", pid: 1 },
    });
  });
  const attach = new ScriptedTransport((request, transport) => {
    transport.emit({ event: "vt-state", surface: 7, cols: 80, rows: 24, data: "A".repeat(9) });
    transport.emit({ id: request.id, ok: true, data: {} });
  });
  const client = new CmuxClient({
    transport: main,
    streamTransportFactory: () => attach,
    timeoutMs: 100,
    maxAttachEncodedChars: 8,
  } as CmuxClientOptionsWithSecurityLimits);

  await assert.rejects(
    () => client.attachSurface(7),
    /vt-state data exceeds 8 encoded characters/,
  );
  await client.close();
});

test("shared attach rejects buffered overflow before its success response", async () => {
  const transport = new ScriptedTransport((request, connection) => {
    if (request.cmd === "identify") {
      connection.emit({
        id: request.id,
        ok: true,
        data: { app: "cmux-tui", version: "0.1.2", protocol: 6, session: "main", pid: 1 },
      });
      return;
    }
    assert.equal(request.cmd, "attach-surface");
    connection.emit({ event: "output", surface: 7, data: "YQ==" });
    connection.emit({ event: "output", surface: 7, data: "Yg==" });
    connection.emit({ id: request.id, ok: true, data: {} });
  });
  const client = new CmuxClient({
    transport,
    timeoutMs: 100,
    maxBufferedEvents: 1,
  } as ConstructorParameters<typeof CmuxClient>[0] & { maxBufferedEvents: number });

  await assert.rejects(() => client.attachSurface(7), /stream event buffer overflow/);
  await client.close();
});

test("attach buffering enforces aggregate bytes and browser-frame limits", async () => {
  for (const events of [
    [
      { event: "output", surface: 7, data: "YWJj" },
      { event: "output", surface: 7, data: "ZGVm" },
    ],
    [{ event: "frame", surface: 7, data: "AAAAA" }],
    [{
      event: "browser-state",
      surface: 7,
      frame: { seq: 1, width: 80, height: 24, data: "AAAAA" },
    }],
    [{
      event: "browser-state",
      surface: 7,
      title: "A".repeat(5),
      frame: null,
    }],
  ]) {
    const transport = new ScriptedTransport((request, connection) => {
      if (request.cmd === "identify") {
        connection.emit({
          id: request.id,
          ok: true,
          data: { app: "cmux-tui", version: "0.1.2", protocol: 6, session: "main", pid: 1 },
        });
        return;
      }
      for (const event of events) connection.emit(event);
      connection.emit({ id: request.id, ok: true, data: {} });
    });
    const client = new CmuxClient({
      transport,
      timeoutMs: 100,
      maxAttachEncodedChars: 4,
    } as CmuxClientOptionsWithSecurityLimits);

    await assert.rejects(() => client.attachSurface(7), /exceeds 4/);
    await client.close();
  }
});

type CmuxClientOptionsWithSecurityLimits = ConstructorParameters<typeof CmuxClient>[0] & {
  maxAttachEncodedChars: number;
};

test("legacy resize response defaults to accepted", async () => {
  const transport = new ScriptedTransport((request, connection) => {
    connection.emit({ id: request.id, ok: true, data: {} });
  });
  const client = new CmuxClient({ transport, timeoutMs: 100 });
  assert.deepEqual(await client.resizeSurface(7, 80, 24), { accepted: true });
  await client.close();
});

test("resize response preserves reservation identity", async () => {
  const transport = new ScriptedTransport((request, connection) => {
    connection.emit({ id: request.id, ok: true, data: { accepted: true, reservation_id: 41 } });
  });
  const client = new CmuxClient({ transport, timeoutMs: 100 });
  assert.deepEqual(await client.resizeSurface(7, 80, 24), { accepted: true, reservation_id: 41 });
  await client.close();
});

test("newPane rejects servers older than protocol 9", async () => {
  const transport = new ScriptedTransport((request, connection) => {
    assert.equal(request.cmd, "identify");
    connection.emit({
      id: request.id,
      ok: true,
      data: { app: "cmux-tui", version: "0.1.2", protocol: 8, session: "main", pid: 1 },
    });
  });
  const client = new CmuxClient({ transport, timeoutMs: 100 });

  await assert.rejects(client.newPane(1), /new-pane requires protocol 9/);
  await client.close();
});

test("setSplitRatio rejects servers older than protocol 8", async () => {
  const transport = new ScriptedTransport((request, connection) => {
    assert.equal(request.cmd, "identify");
    connection.emit({
      id: request.id,
      ok: true,
      data: { app: "cmux-tui", version: "0.1.2", protocol: 7, session: "main", pid: 1 },
    });
  });
  const client = new CmuxClient({ transport, timeoutMs: 100 });

  await assert.rejects(client.setSplitRatio(1, 0.5), /set-split-ratio requires protocol 8/);
  await client.close();
});

test("setSplitRatio accepts newer additive protocols", async () => {
  const transport = new ScriptedTransport((request, connection) => {
    if (request.cmd === "identify") {
      connection.emit({
        id: request.id,
        ok: true,
        data: { app: "cmux-tui", version: "0.1.2", protocol: 9, session: "main", pid: 1 },
      });
      return;
    }
    assert.deepEqual(request, { id: 2, cmd: "set-split-ratio", split: 1, ratio: 0.5 });
    connection.emit({ id: request.id, ok: true, data: {} });
  });
  const client = new CmuxClient({ transport, timeoutMs: 100 });

  await client.setSplitRatio(1, 0.5);
  await client.close();
});

test("attachSurface decodes VT colors, output, and resized payloads", async () => {
  const main = new ScriptedTransport((request, transport) => {
    assert.equal(request.cmd, "identify");
    transport.emit({ id: request.id, ok: true, data: { app: "cmux-tui", version: "0.1.2", protocol: 6, session: "main", pid: 1 } });
  });
  const attach = new ScriptedTransport((request, transport) => {
    assert.deepEqual(request, { id: 2, cmd: "attach-surface", surface: 7 });
    transport.emit({
      event: "vt-state",
      surface: 7,
      cols: 80,
      rows: 24,
      data: "G1s/bA==",
      colors: {
        fg: "#d8d9da",
        bg: "#131415",
        cursor: "#f0f0f0",
        selection_bg: null,
        selection_fg: null,
        palette: { "4": "#ff4f8b" },
        cursor_style: "underline",
        cursor_blink: true,
      },
    });
    transport.emit({ id: request.id, ok: true, data: {} });
    transport.emit({ event: "output", surface: 7, data: "aGk=" });
    transport.emit({
      event: "resized",
      surface: 7,
      cols: 100,
      rows: 30,
      data: "AQID",
      colors: {
        fg: null,
        bg: null,
        cursor: null,
        selection_bg: null,
        selection_fg: null,
        palette: { "5": "#112233" },
      },
    });
  });
  const client = new CmuxClient({
    transport: main,
    streamTransportFactory: () => attach,
    timeoutMs: 100,
  });

  const stream = await client.attachSurface(7);
  const initial = await stream.next();
  const output = await stream.next();
  const resized = await stream.next();
  assert.equal(initial.event, "vt-state");
  if (initial.event === "vt-state") {
    assert.deepEqual(initial.data, Uint8Array.from([27, 91, 63, 108]));
    assert.deepEqual(initial.colors, {
      fg: "#d8d9da",
      bg: "#131415",
      cursor: "#f0f0f0",
      selection_bg: null,
      selection_fg: null,
      palette: { "4": "#ff4f8b" },
      cursor_style: "underline",
      cursor_blink: true,
    });
  }
  assert.equal(output.event, "output");
  if (output.event === "output") assert.deepEqual(output.data, Uint8Array.from([104, 105]));
  assert.equal(resized.event, "resized");
  if (resized.event === "resized") {
    const decoded = resized as DecodedResizedEvent;
    assert.deepEqual(decoded.data, Uint8Array.from([1, 2, 3]));
    assert.deepEqual(decoded.replay, decoded.data);
    assert.deepEqual(decoded.colors?.palette, { "5": "#112233" });
  }
  stream.close();
  await client.close();
});

test("attachSurface accepts protocol 9", async () => {
  const main = new ScriptedTransport((request, transport) => {
    transport.emit({
      id: request.id,
      ok: true,
      data: { app: "cmux-tui", version: "0.1.2", protocol: 9, session: "main", pid: 1 },
    });
  });
  const attach = new ScriptedTransport((request, transport) => {
    assert.equal(request.cmd, "attach-surface");
    transport.emit({ id: request.id, ok: true, data: {} });
  });
  const client = new CmuxClient({
    transport: main,
    streamTransportFactory: () => attach,
    timeoutMs: 100,
  });

  const stream = await client.attachSurface(7);
  stream.close();
  await client.close();
});

test("surface overflow terminates only the matching shared attach stream", async () => {
  const transport = new ScriptedTransport((request, connection) => {
    if (request.cmd === "identify") {
      connection.emit({
        id: request.id,
        ok: true,
        data: { app: "cmux-tui", version: "0.1.2", protocol: 6, session: "main", pid: 1 },
      });
      return;
    }
    assert.ok(request.cmd === "attach-surface" || request.cmd === "subscribe");
    connection.emit({ id: request.id, ok: true, data: {} });
  });
  const client = new CmuxClient({ transport, timeoutMs: 100 });
  const attach = await client.attachSurface(7);
  const subscription = await client.subscribe();

  transport.emit({
    event: "overflow",
    scope: "surface",
    surface: 7,
    error: "surface stream fell behind",
  });
  transport.emit({ event: "overflow", error: "subscriber fell behind" });

  const attachOverflow = await attach.next();
  assert.equal(attachOverflow.event, "overflow");
  await assert.rejects(() => attach.next(), /stream is closed/);
  const subscriptionOverflow = await subscription.next();
  assert.equal(subscriptionOverflow.event, "overflow");
  if (subscriptionOverflow.event === "overflow") {
    assert.equal(subscriptionOverflow.scope, undefined);
  }
  await assert.rejects(() => subscription.next(), /stream is closed/);
  await client.close();
});

test("attachSurface routes colors-changed events without a surface field", async () => {
  const transport = new ScriptedTransport((request, connection) => {
    if (request.cmd === "identify") {
      connection.emit({
        id: request.id,
        ok: true,
        data: { app: "cmux-tui", version: "0.1.2", protocol: 6, session: "main", pid: 1 },
      });
      return;
    }
    assert.equal(request.cmd, "attach-surface");
    connection.emit({ event: "vt-state", surface: 7, cols: 80, rows: 24, data: "" });
    connection.emit({ id: request.id, ok: true, data: {} });
    connection.emit({
      event: "colors-changed",
      fg: "#eeeeee",
      bg: "#1d1f21",
      cursor: null,
      selection_bg: "#334455",
      selection_fg: "#ffffff",
      palette: { "4": "#ff4f8b" },
      cursor_style: "bar",
      cursor_blink: false,
    });
  });
  const client = new CmuxClient({ transport, timeoutMs: 100 });

  const stream = await client.attachSurface(7);
  assert.equal((await stream.next()).event, "vt-state");
  assert.deepEqual(await stream.next(), {
    event: "colors-changed",
    fg: "#eeeeee",
    bg: "#1d1f21",
    cursor: null,
    selection_bg: "#334455",
    selection_fg: "#ffffff",
    palette: { "4": "#ff4f8b" },
    cursor_style: "bar",
    cursor_blink: false,
  });
  stream.close();
  await client.close();
});

test("attachSurface render mode yields render-state and render-delta from cached protocol v7", async () => {
  let identifyRequests = 0;
  const main = new ScriptedTransport((request, transport) => {
    assert.equal(request.cmd, "identify");
    identifyRequests += 1;
    transport.emit({
      id: request.id,
      ok: true,
      data: {
        app: "cmux-tui",
        version: "0.1.2",
        protocol: 7,
        capabilities: ["attach-initial-size"],
        session: "main",
        pid: 1,
      },
    });
  });
  const attach = new ScriptedTransport((request, transport) => {
    assert.deepEqual(request, {
      id: 2,
      cmd: "attach-surface",
      surface: 7,
      mode: "render",
      cols: 120,
      rows: 40,
    });
    transport.emit({
      event: "render-state",
      surface: 7,
      size: { cols: 3, rows: 1 },
      cursor: { x: 2, y: 0, style: "block", blink: true, visible: true, color: null },
      default_fg: "#d8d9da",
      default_bg: "#131415",
      scrollback_rows: 42,
      rows: [{
        row: 0,
        runs: [{
          text: "$ x",
          fg: null,
          bg: null,
          attrs: 1,
          underline: "single",
          width_hint: 3,
        }],
      }],
    });
    transport.emit({ id: request.id, ok: true, data: {} });
    transport.emit({
      event: "render-delta",
      surface: 7,
      cursor: { x: 0, y: 0, style: "bar", blink: false, visible: false, color: "#ffffff" },
      full: false,
      scrollback_rows: 43,
      rows: [{ row: 0, runs: [{ text: "ok ", fg: "#00ff00", bg: null, attrs: 0 }] }],
    });
  });
  const client = new CmuxClient({
    transport: main,
    streamTransportFactory: () => attach,
    timeoutMs: 100,
  });

  assert.equal((await client.identify()).protocol, 7);
  assert.equal(client.protocol, 7);
  const stream = await client.attachSurface(7, { mode: "render", cols: 120, rows: 40 });
  assert.equal(identifyRequests, 1);
  assert.deepEqual(await stream.next(), {
    event: "render-state",
    surface: 7,
    size: { cols: 3, rows: 1 },
    cursor: { x: 2, y: 0, style: "block", blink: true, visible: true, color: null },
    default_fg: "#d8d9da",
    default_bg: "#131415",
    scrollback_rows: 42,
    rows: [{
      row: 0,
      runs: [{
        text: "$ x",
        fg: null,
        bg: null,
        attrs: 1,
        underline: "single",
        width_hint: 3,
      }],
    }],
  });
  assert.deepEqual(await stream.next(), {
    event: "render-delta",
    surface: 7,
    cursor: { x: 0, y: 0, style: "bar", blink: false, visible: false, color: "#ffffff" },
    full: false,
    scrollback_rows: 43,
    rows: [{ row: 0, runs: [{ text: "ok ", fg: "#00ff00", bg: null, attrs: 0 }] }],
  });
  stream.close();
  await client.close();
});

test("attachSurface render mode accepts a newer additive protocol", async () => {
  const main = new ScriptedTransport((request, transport) => {
    assert.equal(request.cmd, "identify");
    transport.emit({
      id: request.id,
      ok: true,
      data: { app: "cmux-tui", version: "0.1.2", protocol: 9, session: "main", pid: 1 },
    });
  });
  const attach = new ScriptedTransport((request, transport) => {
    assert.deepEqual(request, { id: 2, cmd: "attach-surface", surface: 7, mode: "render" });
    transport.emit({ id: request.id, ok: true, data: {} });
  });
  const client = new CmuxClient({
    transport: main,
    streamTransportFactory: () => attach,
    timeoutMs: 100,
  });

  assert.equal((await client.identify()).protocol, 9);
  const stream = await client.attachSurface(7, { mode: "render" });
  stream.close();
  await client.close();
});

test("protocol v6 keeps byte attach working and refuses render mode client-side", async () => {
  let attachRequests = 0;
  const transport = new ScriptedTransport((request, connection) => {
    if (request.cmd === "identify") {
      connection.emit({
        id: request.id,
        ok: true,
        data: { app: "cmux-tui", version: "0.1.2", protocol: 6, session: "main", pid: 1 },
      });
      return;
    }
    attachRequests += 1;
    assert.deepEqual(request, { id: 2, cmd: "attach-surface", surface: 7 });
    connection.emit({ event: "vt-state", surface: 7, cols: 80, rows: 24, data: "" });
    connection.emit({ id: request.id, ok: true, data: {} });
  });
  const client = new CmuxClient({ transport, timeoutMs: 100 });

  await client.identify();
  await assert.rejects(
    client.attachSurface(7, { mode: "render" }),
    (error: unknown) => error instanceof CmuxProtocolError
      && error.message === "render attach requires protocol 7 or newer; server reported protocol 6",
  );
  assert.equal(attachRequests, 0);
  const bytes = await client.attachSurface(7);
  assert.equal((await bytes.next()).event, "vt-state");
  assert.equal(attachRequests, 1);
  bytes.close();
  await client.close();
});

test("protocol v7 refuses initial attach sizing without the advertised capability", async () => {
  let attachRequests = 0;
  const main = new ScriptedTransport((request, transport) => {
    assert.equal(request.cmd, "identify");
    transport.emit({
      id: request.id,
      ok: true,
      data: { app: "cmux-tui", version: "0.1.2", protocol: 7, session: "main", pid: 1 },
    });
  });
  const attach = new ScriptedTransport(() => {
    attachRequests += 1;
  });
  const client = new CmuxClient({
    transport: main,
    streamTransportFactory: () => attach,
    timeoutMs: 100,
  });

  await assert.rejects(
    () => client.attachSurface(7, { cols: 80, rows: 24 }),
    (error: unknown) => error instanceof CmuxProtocolError
      && error.message === "initial attach sizing is not supported by this server",
  );
  assert.equal(attachRequests, 0);
  await client.close();
});

test("attachSurface rejects partial initial sizing before transport", async () => {
  let requests = 0;
  const transport = new ScriptedTransport(() => { requests += 1; });
  const client = new CmuxClient({ transport, timeoutMs: 100 });

  await assert.rejects(
    () => client.attachSurface(7, { cols: 80 } as never),
    (error: unknown) => error instanceof CmuxProtocolError
      && error.message === "attach-surface cols and rows must be supplied together",
  );
  assert.equal(requests, 0);
  await client.close();
});

test("protocol v7 refuses registry CAS mutations without the advertised capability", async () => {
  let mutationRequests = 0;
  const transport = new ScriptedTransport((request, connection) => {
    if (request.cmd === "identify") {
      connection.emit({
        id: request.id,
        ok: true,
        data: { app: "cmux-tui", version: "0.1.2", protocol: 7, session: "main", pid: 1 },
      });
      return;
    }
    mutationRequests += 1;
    connection.emit({ id: request.id, ok: true, data: {} });
  });
  const client = new CmuxClient({ transport });

  await assert.rejects(
    () => client.closeWorkspaceRegistry({ key: "stable", expected_revision: 4 }),
    (error: unknown) => error instanceof CmuxProtocolError
      && error.message === "workspace registry is not supported by this server",
  );
  assert.equal(mutationRequests, 0);
  await client.close();
});

test("generic request preserves exact wire command and typed result", async () => {
  let sent: Record<string, unknown> | undefined;
  const transport = new ScriptedTransport((request, connection) => {
    sent = request;
    connection.emit({
      id: request.id,
      ok: true,
      data: {
        ok: true,
        version: "0.1.2",
        build_commit: "cmux-sha",
        ghostty_commit: "ghostty-sha",
        protocol: 6,
      },
    });
  });
  const client = new CmuxClient({ transport });
  const result = await client.request({ cmd: "ping" });
  assert.equal(result.protocol, 6);
  assert.equal(result.build_commit, "cmux-sha");
  assert.equal(result.ghostty_commit, "ghostty-sha");
  assert.deepEqual(sent, { id: 1, cmd: "ping" });
  await client.close();
});

test("workspace registry methods preserve keys and revisions", async () => {
  const expected = [
    { id: 2, cmd: "create-workspace", name: "gui", key: "stable", expected_revision: 4 },
    { id: 3, cmd: "create-terminal", key: "stable", command: "echo ready" },
    { id: 4, cmd: "rename-workspace", key: "stable", name: "renamed", expected_revision: 5 },
    { id: 5, cmd: "move-workspace", key: "stable", index: 0, expected_revision: 6 },
    { id: 6, cmd: "close-workspace", key: "stable", expected_revision: 7 },
  ];
  const responses = [
    { workspace: 1, key: "stable", index: 0, workspace_revision: 5 },
    { surface: 4, pane: 3, screen: 2, workspace: 1, key: "stable" },
    { workspace: 1, key: "stable", workspace_revision: 6 },
    { workspace: 1, key: "stable", workspace_revision: 7 },
    { workspace: 1, key: "stable", workspace_revision: 8 },
  ];
  let index = 0;
  const transport = new ScriptedTransport((request, connection) => {
    if (request.cmd === "identify") {
      connection.emit({
        id: request.id,
        ok: true,
        data: {
          app: "cmux-tui",
          version: "0.1.2",
          protocol: 7,
          capabilities: ["workspace-registry-v1"],
          session: "main",
          pid: 1,
        },
      });
      return;
    }
    assert.deepEqual(request, expected[index]);
    connection.emit({ id: request.id, ok: true, data: responses[index] });
    index += 1;
  });
  const client = new CmuxClient({ transport });

  assert.equal((await client.createWorkspace({ name: "gui", key: "stable", expected_revision: 4 })).workspace_revision, 5);
  assert.equal((await client.createTerminal({ key: "stable", command: "echo ready" })).surface, 4);
  assert.equal((await client.renameWorkspaceRegistry({ key: "stable", name: "renamed", expected_revision: 5 })).workspace_revision, 6);
  assert.equal((await client.moveWorkspaceRegistry({ key: "stable", index: 0, expected_revision: 6 })).workspace_revision, 7);
  assert.equal((await client.closeWorkspaceRegistry({ key: "stable", expected_revision: 7 })).workspace_revision, 8);
  await client.close();
});

test("setSplitRatio sends the stable split id", async () => {
  let sent: Record<string, unknown> | undefined;
  const transport = new ScriptedTransport((request, connection) => {
    if (request.cmd === "identify") {
      connection.emit({
        id: request.id,
        ok: true,
        data: { app: "cmux-tui", version: "0.1.2", protocol: 8, session: "main", pid: 1 },
      });
    } else {
      sent = request;
      connection.emit({ id: request.id, ok: true, data: {} });
    }
  });
  const client = new CmuxClient({ transport });

  await client.setSplitRatio(42, 0.65);

  assert.deepEqual(sent, { id: 2, cmd: "set-split-ratio", split: 42, ratio: 0.65 });
  await client.close();
});

test("listClients returns the exact client presence response shape", async () => {
  const response = [{
    client: 7,
    transport: "ws",
    name: "Safari on iPad",
    kind: "web",
    connected_seconds: 12,
    attached: [31],
    sizes: [{ surface: 31, cols: 126, rows: 38 }],
    self: true,
    size_participating: true,
  }];
  const transport = new ScriptedTransport((request, connection) => {
    assert.deepEqual(request, { id: 1, cmd: "list-clients" });
    connection.emit({ id: request.id, ok: true, data: response });
  });
  const client = new CmuxClient({ transport });

  assert.deepEqual(await client.listClients(), response);
  await client.close();
});

test("setClientSizing serializes client participation", async () => {
  const transport = new ScriptedTransport((request, connection) => {
    assert.deepEqual(request, {
      id: 1,
      cmd: "set-client-sizing",
      client: 7,
      enabled: false,
    });
    connection.emit({ id: request.id, ok: true, data: {} });
  });
  const client = new CmuxClient({ transport });

  await client.setClientSizing(7, false);
  await client.close();
});

test("client sizing modes serialize as one atomic command", async () => {
  const expected = [
    { id: 1, cmd: "set-client-sizing", client: 7, enabled: true, exclusive: true },
    { id: 2, cmd: "set-client-sizing", enabled: true },
  ];
  const transport = new ScriptedTransport((request, connection) => {
    assert.deepEqual(request, expected.shift());
    connection.emit({ id: request.id, ok: true, data: {} });
  });
  const client = new CmuxClient({ transport });

  await client.useOnlyClientSizing(7);
  await client.useAllClientSizing();
  assert.equal(expected.length, 0);
  await client.close();
});

test("readScrollback serializes the request and returns styled rows", async () => {
  const response = {
    rows: [{ row: 0, runs: [{ text: "cargo test", fg: null, bg: null, attrs: 0 }] }],
    start: 40,
    total: 83,
  };
  const transport = new ScriptedTransport((request, connection) => {
    assert.deepEqual(request, { id: 1, cmd: "read-scrollback", surface: 7, start: 40, count: 1 });
    connection.emit({ id: request.id, ok: true, data: response });
  });
  const client = new CmuxClient({ transport });

  assert.deepEqual(await client.readScrollback(7, 40, 1), response);
  await client.close();
});

test("send serializes base64 input and the protocol v7 paste flag", async () => {
  const transport = new ScriptedTransport((request, connection) => {
    assert.deepEqual(request, {
      id: 1,
      cmd: "send",
      surface: 7,
      text: "hello",
      bytes: "AAEC",
      paste: true,
    });
    connection.emit({ id: request.id, ok: true, data: {} });
  });
  const client = new CmuxClient({ transport });

  await client.send(7, { text: "hello", base64: "AAEC", paste: true });
  await client.close();
});

test("protocol v7 commands preserve protocol v6 server failures as command errors", async () => {
  const transport = new ScriptedTransport((request, connection) => {
    connection.emit({
      id: request.id,
      ok: false,
      error: `protocol 6 rejected ${String(request.cmd)}`,
    });
  });
  const client = new CmuxClient({ transport });

  await assert.rejects(client.readScrollback(7, 0, 1), CmuxCommandError);
  await assert.rejects(client.send(7, { text: "hello", paste: true }), CmuxCommandError);
  await assert.rejects(client.subscribe({ treeEvents: "deltas" }), CmuxCommandError);
  await client.close();
});

test("subscribe yields client attached, changed, and detached events", async () => {
  const transport = new ScriptedTransport((request, connection) => {
    assert.deepEqual(request, { id: 1, cmd: "subscribe" });
    connection.emit({ event: "client-attached", client: 2, transport: "ws", name: "phone", kind: "web" });
    connection.emit({ id: request.id, ok: true, data: {} });
    connection.emit({ event: "client-changed", client: 2, name: "tablet", kind: "web" });
    connection.emit({ event: "client-detached", client: 2 });
  });
  const client = new CmuxClient({ transport, timeoutMs: 100 });

  const events = await client.subscribe();
  assert.deepEqual(await events.next(), {
    event: "client-attached",
    client: 2,
    transport: "ws",
    name: "phone",
    kind: "web",
  });
  assert.deepEqual(await events.next(), { event: "client-changed", client: 2, name: "tablet", kind: "web" });
  assert.deepEqual(await events.next(), { event: "client-detached", client: 2 });
  events.close();
  await client.close();
});

test("concurrent shared subscriptions require dedicated transports", async () => {
  const transport = new ScriptedTransport((request, connection) => {
    assert.equal(request.cmd, "subscribe");
    connection.emit({ id: request.id, ok: true, data: {} });
  });
  const client = new CmuxClient({ transport, timeoutMs: 100 });
  const first = await client.subscribe();

  await assert.rejects(
    () => client.subscribe(),
    /concurrent subscriptions require streamTransportFactory/,
  );

  first.close();
  const replacement = await client.subscribe();
  replacement.close();
  await client.close();
});

test("subscribe deltas mode yields all protocol v7 tree lifecycle events", async () => {
  const tab = {
    surface: 4,
    kind: "pty" as const,
    browser_source: null,
    name: "shell",
    title: "shell",
    size: { cols: 80, rows: 24 },
    dead: false,
  };
  const pane = { id: 3, name: null, active_tab: 0, tabs: [tab] };
  const screen = {
    id: 2,
    name: null,
    active: true,
    active_pane: 3,
    zoomed_pane: null,
    layout: { type: "leaf" as const, pane: 3 },
    panes: [pane],
  };
  const workspace = { id: 1, key: "stable", name: "sdk", active: true, screens: [screen] };
  const deltas: TreeDeltaEvent[] = [
    { event: "workspace-added", workspace: 1, index: 0, workspace_revision: 1, entity: workspace },
    { event: "workspace-closed", workspace: 1, index: 0, workspace_revision: 4, entity: workspace },
    { event: "workspace-renamed", workspace: 1, workspace_revision: 2, entity: workspace },
    { event: "workspace-moved", workspace: 1, index: 0, workspace_revision: 3, entity: workspace },
    { event: "screen-added", workspace: 1, screen: 2, index: 0, entity: screen },
    { event: "screen-closed", workspace: 1, screen: 2, index: 0, entity: screen },
    { event: "screen-renamed", workspace: 1, screen: 2, entity: screen },
    { event: "pane-added", workspace: 1, screen: 2, pane: 3, index: 0, entity: pane },
    { event: "pane-closed", workspace: 1, screen: 2, pane: 3, index: 0, entity: pane },
    { event: "tab-added", workspace: 1, screen: 2, pane: 3, surface: 4, index: 0, entity: tab },
    { event: "tab-closed", workspace: 1, screen: 2, pane: 3, surface: 4, index: 0, entity: tab },
    { event: "tab-renamed", workspace: 1, screen: 2, pane: 3, surface: 4, entity: tab },
  ];
  const transport = new ScriptedTransport((request, connection) => {
    assert.deepEqual(request, { id: 1, cmd: "subscribe", tree_events: "deltas" });
    for (const event of deltas) connection.emit(event as unknown as Record<string, unknown>);
    connection.emit({ id: request.id, ok: true, data: {} });
  });
  const client = new CmuxClient({ transport, timeoutMs: 100 });

  const events = await client.subscribe({ treeEvents: "deltas" });
  for (const expected of deltas) assert.deepEqual(await events.next(), expected);
  events.close();
  await client.close();
});
