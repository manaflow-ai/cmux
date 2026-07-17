import assert from "node:assert/strict";
import test from "node:test";
import { CmuxClient, CmuxStream } from "../src/client.js";
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

test("attachSurface decodes VT colors, output, and resized payloads", async () => {
  const main = new ScriptedTransport((request, transport) => {
    assert.equal(request.cmd, "identify");
    transport.emit({ id: request.id, ok: true, data: { app: "cmux-tui", version: "0.1.2", protocol: 6, session: "main", pid: 1 } });
  });
  const attach = new ScriptedTransport((request, transport) => {
    assert.equal(request.cmd, "attach-surface");
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
        cursor_style: "underline",
        cursor_blink: true,
      },
    });
    transport.emit({ id: request.id, ok: true, data: {} });
    transport.emit({ event: "output", surface: 7, data: "aGk=" });
    transport.emit({ event: "resized", surface: 7, cols: 100, rows: 30, data: "AQID" });
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
      cursor_style: "underline",
      cursor_blink: true,
    });
  }
  assert.equal(output.event, "output");
  if (output.event === "output") assert.deepEqual(output.data, Uint8Array.from([104, 105]));
  assert.equal(resized.event, "resized");
  if (resized.event === "resized") {
    assert.deepEqual(resized.data, Uint8Array.from([1, 2, 3]));
    assert.deepEqual(resized.replay, resized.data);
  }
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
    cursor_style: "bar",
    cursor_blink: false,
  });
  stream.close();
  await client.close();
});

test("generic request preserves exact wire command and typed result", async () => {
  let sent: Record<string, unknown> | undefined;
  const transport = new ScriptedTransport((request, connection) => {
    sent = request;
    connection.emit({ id: request.id, ok: true, data: { ok: true, version: "0.1.2", protocol: 6 } });
  });
  const client = new CmuxClient({ transport });
  const result = await client.request({ cmd: "ping" });
  assert.equal(result.protocol, 6);
  assert.deepEqual(sent, { id: 1, cmd: "ping" });
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
  }];
  const transport = new ScriptedTransport((request, connection) => {
    assert.deepEqual(request, { id: 1, cmd: "list-clients" });
    connection.emit({ id: request.id, ok: true, data: response });
  });
  const client = new CmuxClient({ transport });

  assert.deepEqual(await client.listClients(), response);
  await client.close();
});

test("subscribe yields client attached, changed, and detached events", async () => {
  const transport = new ScriptedTransport((request, connection) => {
    assert.equal(request.cmd, "subscribe");
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
