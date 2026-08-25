import assert from "node:assert/strict";
import test from "node:test";
import {
  CmuxClient,
  CmuxStream,
  DEFAULT_MAX_ATTACH_ENCODED_CHARS,
  MAX_ATTACH_HANDSHAKE_TIMEOUT_MS,
  MIN_ATTACH_HANDSHAKE_BYTES_PER_SECOND,
  defaultAttachHandshakeTimeoutMs,
  type BrowserStreamEvent,
} from "../src/raw/client.js";
import {
  CmuxAbortError,
  CmuxCommandError,
  CmuxProtocolError,
  CmuxTimeoutError,
} from "../src/raw/errors.js";
import type {
  DecodedResizedEvent,
  RenderStateEvent,
  TreeDeltaEvent,
} from "../src/raw/protocol/index.js";
import type { Transport, Unsubscribe } from "../src/transport.js";
import {
  RENDER_ATTACH_MAX_ENCODED_CHARS,
  RENDER_GRAPHIC_MAX_DECODED_BYTES,
  RENDER_GRAPHIC_MAX_ENCODED_CHARS,
  RENDER_GRAPHIC_MAX_IMAGES,
  RENDER_GRAPHIC_MAX_PLACEMENTS,
} from "../src/transport-limits.js";
import { stringifyWireJson } from "../src/wire-json.js";

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
    const data = value.data;
    const enriched = value.ok === true
      && data
      && typeof data === "object"
      && !Array.isArray(data)
      && (data as Record<string, unknown>).app === "cmux-tui"
      ? {
        ...value,
        data: completeIdentifyResult(data as Record<string, unknown>),
      }
      : value;
    const json = stringifyWireJson(enriched);
    for (const handler of this.messageHandlers) handler(json);
  }
}

class SubscriptionTrackingTransport implements Transport {
  messageSubscriptions = 0;
  closeSubscriptions = 0;
  errorSubscriptions = 0;

  send(): void {}
  onMessage(): Unsubscribe {
    this.messageSubscriptions += 1;
    return () => undefined;
  }
  onClose(): Unsubscribe {
    this.closeSubscriptions += 1;
    return () => undefined;
  }
  onError(): Unsubscribe {
    this.errorSubscriptions += 1;
    return () => undefined;
  }
  close(): void {}
}

function completeIdentifyResult(
  data: Record<string, unknown>,
): Record<string, unknown> {
  const protocol = typeof data.protocol === "number" ? data.protocol : 5;
  return {
    ...(protocol >= 7
      ? {
        registry_id: "registry",
        generation: "generation",
        workspace_revision: 1n,
      }
      : {}),
    ...(protocol >= 9
      ? {
        terminal_revision: 1n,
        daemon_handoff: 1,
      }
      : {}),
    ...data,
  };
}

function identifyResult(
  protocol = 6,
  capabilities: readonly string[] = [],
): Record<string, unknown> {
  return completeIdentifyResult({
    app: "cmux-tui",
    version: "0.1.2",
    protocol,
    session: "main",
    pid: 1,
    capabilities: [...capabilities],
  });
}

test("client constructor rejects invalid command timeouts before subscribing", () => {
  for (const timeoutMs of [-1, Number.NaN, Number.POSITIVE_INFINITY, 0x8000_0000]) {
    const transport = new SubscriptionTrackingTransport();

    assert.throws(
      () => new CmuxClient({ transport, timeoutMs }),
      (error: unknown) => {
        assert.ok(error instanceof TypeError);
        assert.equal(error.message, "timeoutMs must be between 0 and 2147483647");
        return true;
      },
    );
    assert.deepEqual({
      message: transport.messageSubscriptions,
      close: transport.closeSubscriptions,
      error: transport.errorSubscriptions,
    }, { message: 0, close: 0, error: 0 });
  }
});

function deferred(): { promise: Promise<void>; resolve: () => void } {
  let resolve!: () => void;
  const promise = new Promise<void>((complete) => {
    resolve = complete;
  });
  return { promise, resolve };
}

function trackSettlement(promise: Promise<unknown>): () => boolean {
  let settled = false;
  void promise.then(
    () => {
      settled = true;
    },
    () => {
      settled = true;
    },
  );
  return () => settled;
}

class TrackingAbortSignal {
  aborted = false;
  added = 0;
  removed = 0;
  private readonly listeners = new Set<EventListenerOrEventListenerObject>();

  readonly signal = this as unknown as AbortSignal;

  addEventListener(
    type: string,
    listener: EventListenerOrEventListenerObject,
  ): void {
    if (type !== "abort") return;
    this.added += 1;
    this.listeners.add(listener);
  }

  removeEventListener(
    type: string,
    listener: EventListenerOrEventListenerObject,
  ): void {
    if (type !== "abort") return;
    this.removed += 1;
    this.listeners.delete(listener);
  }

  abort(): void {
    if (this.aborted) return;
    this.aborted = true;
    const event = new Event("abort");
    for (const listener of [...this.listeners]) {
      if (typeof listener === "function") listener(event);
      else listener.handleEvent(event);
    }
  }
}

test("streams wait indefinitely by default and support explicit idle timeouts", async (context) => {
  context.mock.timers.enable({ apis: ["setTimeout"] });
  const quiet = new CmuxStream<{ event: string }>(undefined, () => undefined);
  const pending = quiet.next();
  const pendingSettled = trackSettlement(pending);
  context.mock.timers.tick(6);
  await Promise.resolve();
  assert.equal(pendingSettled(), false);
  assert.equal(quiet.idleTimeoutMs, undefined);
  quiet.push({ event: "ready" });
  assert.deepEqual(await pending, { event: "ready" });
  quiet.close();

  const finite = new CmuxStream<{ event: string }>(5, () => undefined);
  const timed = finite.next();
  context.mock.timers.tick(5);
  await assert.rejects(() => timed, CmuxTimeoutError);
  finite.push({ event: "after-timeout" });
  assert.deepEqual(await finite.next({ timeoutMs: 20 }), { event: "after-timeout" });
  finite.close();
});

test("client command timeout does not become a stream idle timeout", async (context) => {
  context.mock.timers.enable({ apis: ["setTimeout"] });
  let connection: ScriptedTransport | undefined;
  const transport = new ScriptedTransport((request, current) => {
    connection = current;
    current.emit({
      id: request.id,
      ok: true,
      data: request.cmd === "identify" ? identifyResult() : {},
    });
  });
  const client = new CmuxClient({ transport, timeoutMs: 5 });
  const stream = await client.subscribe();
  const pending = stream.next();
  const pendingSettled = trackSettlement(pending);
  context.mock.timers.tick(6);
  await Promise.resolve();
  assert.equal(pendingSettled(), false);
  assert.equal(stream.idleTimeoutMs, undefined);
  connection?.emit({ event: "tree-changed" });
  assert.deepEqual(await pending, { event: "tree-changed" });
  stream.close();
  await client.close();
});

test("client and per-stream idle timeout options remain finite opt-ins", async () => {
  const transport = new ScriptedTransport((request, connection) => {
    connection.emit({
      id: request.id,
      ok: true,
      data: request.cmd === "identify" ? identifyResult() : {},
    });
  });
  const client = new CmuxClient({
    transport,
    timeoutMs: 100,
    streamIdleTimeoutMs: 10,
  });
  const inherited = await client.subscribe();
  await assert.rejects(() => inherited.next(), CmuxTimeoutError);
  inherited.close();

  const overridden = await client.subscribe({ idleTimeoutMs: 5 });
  assert.equal(overridden.idleTimeoutMs, 5);
  await assert.rejects(() => overridden.next(), CmuxTimeoutError);
  overridden.close();
  await client.close();
});

test("aborting one pending stream read removes its listener without closing the stream", async () => {
  const stream = new CmuxStream<{ event: string }>(undefined, () => undefined);
  const cancelled = new TrackingAbortSignal();
  const pending = stream.next({ signal: cancelled.signal });
  assert.equal(cancelled.added, 1);
  cancelled.abort();
  await assert.rejects(() => pending, CmuxAbortError);
  assert.equal(cancelled.removed, 1);

  const delivered = new TrackingAbortSignal();
  const next = stream.next({ signal: delivered.signal, timeoutMs: 20 });
  stream.push({ event: "still-open" });
  assert.deepEqual(await next, { event: "still-open" });
  assert.equal(delivered.added, 1);
  assert.equal(delivered.removed, 1);
  stream.close();
});

test("pending read listeners are removed on timeout and close", async () => {
  const stream = new CmuxStream<{ event: string }>(undefined, () => undefined);
  const timed = new TrackingAbortSignal();
  await assert.rejects(
    () => stream.next({ signal: timed.signal, timeoutMs: 5 }),
    CmuxTimeoutError,
  );
  assert.equal(timed.added, 1);
  assert.equal(timed.removed, 1);

  const closed = new TrackingAbortSignal();
  const pending = stream.next({ signal: closed.signal });
  stream.close();
  await assert.rejects(() => pending, /stream is closed/);
  assert.equal(closed.added, 1);
  assert.equal(closed.removed, 1);
});

test("AbortSignal cancels a pending stream open and releases shared subscription state", {
  timeout: 1_000,
}, async () => {
  let subscriptions = 0;
  const firstSubscriptionSent = deferred();
  const transport = new ScriptedTransport((request, connection) => {
    if (request.cmd === "identify") {
      connection.emit({ id: request.id, ok: true, data: identifyResult() });
      return;
    }
    assert.equal(request.cmd, "subscribe");
    subscriptions += 1;
    if (subscriptions === 1) firstSubscriptionSent.resolve();
    if (subscriptions === 2) {
      connection.emit({ id: request.id, ok: true, data: {} });
    }
  });
  const client = new CmuxClient({ transport, timeoutMs: 100 });
  const cancelled = new TrackingAbortSignal();
  const opening = client.subscribe({ signal: cancelled.signal });
  await firstSubscriptionSent.promise;
  assert.equal(subscriptions, 1);
  cancelled.abort();
  await assert.rejects(() => opening, CmuxAbortError);
  assert.equal(cancelled.added, 2);
  assert.equal(cancelled.removed, 2);

  const replacement = await client.subscribe();
  assert.equal(subscriptions, 2);
  replacement.close();
  await client.close();
});

test("AbortSignal cancels the identification phase of a browser stream open", {
  timeout: 1_000,
}, async () => {
  let requests = 0;
  const firstRequestSent = deferred();
  const transport = new ScriptedTransport(() => {
    requests += 1;
    firstRequestSent.resolve();
  });
  const client = new CmuxClient({ transport, timeoutMs: 100 });
  const cancelled = new TrackingAbortSignal();
  const opening = client.attachBrowserSurface(7n, { signal: cancelled.signal });
  await firstRequestSent.promise;
  assert.equal(requests, 1);
  cancelled.abort();
  await assert.rejects(() => opening, CmuxAbortError);
  assert.equal(cancelled.added, 1);
  assert.equal(cancelled.removed, 1);
  await client.close();
});

test("a stream-lifetime signal aborts an unbounded pending read without listener leaks", async () => {
  const transport = new ScriptedTransport((request, connection) => {
    connection.emit({
      id: request.id,
      ok: true,
      data: request.cmd === "identify" ? identifyResult() : {},
    });
  });
  const client = new CmuxClient({ transport, timeoutMs: 100 });
  const lifetime = new TrackingAbortSignal();
  const stream = await client.subscribe({ signal: lifetime.signal });
  const pending = stream.next();
  lifetime.abort();
  await assert.rejects(() => pending, CmuxAbortError);
  assert.equal(lifetime.added, 3);
  assert.equal(lifetime.removed, 3);
  await client.close();
});

test("closing a signalled stream removes both open and lifetime listeners", async () => {
  const transport = new ScriptedTransport((request, connection) => {
    connection.emit({
      id: request.id,
      ok: true,
      data: request.cmd === "identify" ? identifyResult() : {},
    });
  });
  const client = new CmuxClient({ transport, timeoutMs: 100 });
  const lifetime = new TrackingAbortSignal();
  const stream = await client.subscribe({ signal: lifetime.signal });
  assert.equal(lifetime.added, 3);
  assert.equal(lifetime.removed, 2);
  stream.close();
  assert.equal(lifetime.removed, 3);
  await client.close();
});

test("attachBrowserSurface yields only sound browser discriminants", async () => {
  let attachRequest: Record<string, unknown> | undefined;
  const main = new ScriptedTransport((request, connection) => {
    connection.emit({
      id: request.id,
      ok: true,
      data: { app: "cmux-tui", version: "0.1.2", protocol: 10, session: "main", pid: 1 },
    });
  });
  const attach = new ScriptedTransport((request, connection) => {
    attachRequest = request;
    connection.emit({
      event: "browser-state",
      surface: 7,
      cols: 80,
      rows: 24,
      url: "https://example.com",
      title: "Example",
      status: "live",
      error: null,
      frames_stalled: false,
      frame: { seq: 1, width: 800, height: 600, data: "YQ==" },
    });
    connection.emit({
      event: "frame",
      surface: 7,
      seq: 2,
      width: 800,
      height: 600,
      data: "Yg==",
    });
    connection.emit({ id: request.id, ok: true, data: {} });
  });
  const client = new CmuxClient({
    transport: main,
    streamTransportFactory: () => attach,
    timeoutMs: 100,
  });

  const stream = await client.attachBrowserSurface(7n);
  const state: BrowserStreamEvent = await stream.next();
  assert.equal(state.event, "browser-state");
  if (state.event === "browser-state") {
    assert.equal(state.url, "https://example.com");
    assert.equal(state.frame?.seq, 1n);
  }
  const frame: BrowserStreamEvent = await stream.next();
  assert.equal(frame.event, "frame");
  if (frame.event === "frame") assert.equal(frame.seq, 2n);
  assert.equal(attachRequest?.mode, undefined);
  assert.equal(attachRequest?.signal, undefined);
  assert.equal(attachRequest?.idleTimeoutMs, undefined);
  stream.close();
  await client.close();
});

test("attachBrowserSurface wraps future events without losing their wire payload", async () => {
  const maximum = 18_446_744_073_709_551_615n;
  const main = new ScriptedTransport((request, connection) => {
    connection.emit({
      id: request.id,
      ok: true,
      data: { app: "cmux-tui", version: "0.1.2", protocol: 10, session: "main", pid: 1 },
    });
  });
  const attach = new ScriptedTransport((request, connection) => {
    connection.emit({
      event: "future-browser-event",
      surface: 7,
      seq: maximum,
      nested: { revision: maximum - 1n },
      optional: null,
    });
    connection.emit({
      event: "frame",
      surface: 7,
      seq: 3,
      width: 800,
      height: 600,
      data: "Yw==",
    });
    connection.emit({ id: request.id, ok: true, data: {} });
  });
  const client = new CmuxClient({
    transport: main,
    streamTransportFactory: () => attach,
    timeoutMs: 100,
  });

  const stream = await client.attachBrowserSurface(7n);
  const future: BrowserStreamEvent = await stream.next();
  assert.deepEqual(future, {
    event: "unknown",
    wireEvent: "future-browser-event",
    raw: {
      event: "future-browser-event",
      surface: 7,
      seq: maximum,
      nested: { revision: maximum - 1n },
      optional: null,
    },
  });
  assert.equal(stream.error, null);
  const frame = await stream.next();
  assert.equal(frame.event, "frame");
  if (frame.event === "frame") assert.equal(frame.seq, 3n);
  stream.close();
  await client.close();
});

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

test("stream rejects an oversized event while a reader is already waiting", async () => {
  const stream = new CmuxStream<{ event: string; bytes: number }>(
    100,
    () => undefined,
    256,
    4,
    (event) => event.bytes,
  );
  const waiting = stream.next();

  stream.push({ event: "oversized", bytes: 5 });

  await assert.rejects(() => waiting, /stream event data exceeds 4 bytes/);
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
    () => client.attachSurface(7n),
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

  await assert.rejects(() => client.attachSurface(7n), /stream event buffer overflow/);
  await client.close();
});

test("attach buffering enforces aggregate bytes and browser-frame limits", async () => {
  for (const events of [
    [
      { event: "output", surface: 7, data: "YWJj" },
      { event: "output", surface: 7, data: "ZGVm" },
    ],
    [{
      event: "frame",
      surface: 7,
      seq: 1,
      width: 80,
      height: 24,
      data: "AAAAA",
    }],
    [{
      event: "browser-state",
      surface: 7,
      cols: 80,
      rows: 24,
      url: "https://example.com",
      title: "Example",
      status: "live",
      error: null,
      frames_stalled: false,
      frame: { seq: 1, width: 80, height: 24, data: "AAAAA" },
    }],
    [{
      event: "browser-state",
      surface: 7,
      cols: 80,
      rows: 24,
      url: "https://example.com",
      title: "A".repeat(5),
      status: "live",
      error: null,
      frames_stalled: false,
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

    await assert.rejects(() => client.attachSurface(7n), /exceeds 4/);
    await client.close();
  }
});

type CmuxClientOptionsWithSecurityLimits = ConstructorParameters<typeof CmuxClient>[0] & {
  maxAttachEncodedChars: number;
};

test("attach handshake deadline accounts for the largest accepted snapshot", () => {
  assert.equal(MIN_ATTACH_HANDSHAKE_BYTES_PER_SECOND, 64 * 1024);
  assert.equal(MAX_ATTACH_HANDSHAKE_TIMEOUT_MS, 15 * 60 * 1_000);
  assert.equal(
    defaultAttachHandshakeTimeoutMs(10_000, RENDER_ATTACH_MAX_ENCODED_CHARS),
    522_000,
  );
});

test("attach stream can acknowledge after the ordinary request deadline", async () => {
  const main = new ScriptedTransport((request, transport) => {
    transport.emit({
      id: request.id,
      ok: true,
      data: { app: "cmux-tui", version: "0.1.2", protocol: 7, session: "main", pid: 1 },
    });
  });
  const attach = new ScriptedTransport((request, transport) => {
    transport.emit({
      event: "render-state",
      surface: 7,
      size: { cols: 1, rows: 1 },
      cursor: { x: 0, y: 0, style: "block", blink: false, visible: false, color: null },
      default_fg: "#ffffff",
      default_bg: "#000000",
      scrollback_rows: 0,
      rows: [],
      graphics: { generation: 0, images: [], placements: [] },
    });
    setTimeout(() => transport.emit({ id: request.id, ok: true, data: {} }), 30);
  });
  const client = new CmuxClient({
    transport: main,
    streamTransportFactory: () => attach,
    timeoutMs: 10,
    attachHandshakeTimeoutMs: 100,
  });

  const stream = await client.attachSurface(7n, { mode: "render" });
  assert.equal((await stream.next()).event, "render-state");
  stream.close();
  await client.close();
});

test("vtState uses the size-aware snapshot deadline", async () => {
  const transport = new ScriptedTransport((request, connection) => {
    assert.equal(request.cmd, "vt-state");
    setTimeout(() => {
      connection.emit({
        id: request.id,
        ok: true,
        data: { cols: 80, rows: 24, data: "" },
      });
    }, 30);
  });
  const client = new CmuxClient({
    transport,
    timeoutMs: 10,
    attachHandshakeTimeoutMs: 100,
  });

  assert.deepEqual(await client.vtState(7n), { cols: 80, rows: 24, data: "" });
  await client.close();
});

test("resize response rejects a missing required accepted field", async () => {
  const transport = new ScriptedTransport((request, connection) => {
    connection.emit({
      id: request.id,
      ok: true,
      data: request.cmd === "identify" ? identifyResult(6) : {},
    });
  });
  const client = new CmuxClient({ transport, timeoutMs: 100 });
  await assert.rejects(
    () => client.resizeSurface(7n, 80, 24),
    /resize-surface result\.accepted is required/,
  );
  await client.close();
});

test("resize response preserves reservation identity", async () => {
  const transport = new ScriptedTransport((request, connection) => {
    connection.emit({
      id: request.id,
      ok: true,
      data: request.cmd === "identify"
        ? identifyResult(7)
        : { accepted: true, reservation_id: 41 },
    });
  });
  const client = new CmuxClient({ transport, timeoutMs: 100 });
  assert.deepEqual(await client.resizeSurface(7n, 80, 24), { accepted: true, reservation_id: 41n });
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

  await assert.rejects(client.newPane(1n), /new-pane requires protocol 9/);
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

  await assert.rejects(client.setSplitRatio(1n, 0.5), /set-split-ratio requires protocol 8/);
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

  await client.setSplitRatio(1n, 0.5);
  await client.close();
});

test("stable terminal resolve and close serialize process identity", async () => {
  const terminalId = "0123456789abcdef0123456789abcdef";
  const incarnation = "fedcba9876543210fedcba9876543210";
  const transport = new ScriptedTransport((request, connection) => {
    if (request.cmd === "identify") {
      connection.emit({
        id: request.id,
        ok: true,
        data: { app: "cmux-tui", version: "0.1.2", protocol: 9, session: "main", pid: 1 },
      });
      return;
    }
    if (request.cmd === "resolve-terminal") {
      assert.deepEqual(request, {
        id: 2,
        cmd: "resolve-terminal",
        terminal_id: terminalId,
      });
    } else {
      assert.deepEqual(request, {
        id: 3,
        cmd: "close-terminal",
        terminal_id: terminalId,
        terminal_incarnation: incarnation,
      });
    }
    connection.emit({
      id: request.id,
      ok: true,
      data: request.cmd === "resolve-terminal"
        ? {
          surface: 7,
          terminal_id: terminalId,
          terminal_incarnation: incarnation,
          workspace_key: "stable",
          lifecycle: "running",
          launch_spec: {},
          exit: null,
          terminal_revision: 1,
          registry_id: "registry",
          generation: "generation",
        }
        : {
          surface: 7,
          terminal_id: terminalId,
          terminal_incarnation: incarnation,
          already_closed: false,
          closed: true,
          terminal_revision: 2,
          registry_id: "registry",
          generation: "generation",
        },
    });
  });
  const client = new CmuxClient({ transport, timeoutMs: 100 });

  assert.equal((await client.resolveTerminal(terminalId)).surface, 7n);
  assert.equal((await client.closeTerminal(terminalId, incarnation)).surface, 7n);
  await client.close();
});

test("attachSurface decodes VT colors, output, and resized payloads", async () => {
  const atomicColors = {
    fg: "#010203",
    bg: "#040506",
    cursor: null,
    selection_bg: null,
    selection_fg: null,
    cursor_style: null,
    cursor_blink: null,
  };
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
      kitty_image_aliases: [{ image_id: 7, image_number: 70 }],
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
    transport.emit({ event: "output", surface: 7, data: "aGk=", colors: atomicColors });
    transport.emit({
      event: "resized",
      surface: 7,
      cols: 100,
      rows: 30,
      data: "AQID",
      kitty_image_aliases: [{ image_id: 8, image_number: 80 }],
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

  const stream = await client.attachSurface(7n);
  const initial = await stream.next();
  const output = await stream.next();
  const resized = await stream.next();
  assert.equal(initial.event, "vt-state");
  if (initial.event === "vt-state") {
    assert.deepEqual(initial.data, Uint8Array.from([27, 91, 63, 108]));
    assert.deepEqual(initial.kitty_image_aliases, [{ image_id: 7, image_number: 70 }]);
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
  if (output.event === "output") {
    assert.deepEqual(output.data, Uint8Array.from([104, 105]));
    assert.deepEqual(output.colors, atomicColors);
  }
  assert.equal(resized.event, "resized");
  if (resized.event === "resized") {
    const decoded = resized as DecodedResizedEvent;
    assert.deepEqual(decoded.data, Uint8Array.from([1, 2, 3]));
    assert.deepEqual(decoded.replay, decoded.data);
    assert.deepEqual(decoded.kitty_image_aliases, [{ image_id: 8, image_number: 80 }]);
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

  const stream = await client.attachSurface(7n);
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
  const attach = await client.attachSurface(7n);
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

  const stream = await client.attachSurface(7n);
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

const renderGraphics = {
  generation: 4n,
  images: [{
    id: 9,
    generation: 2n,
    width: 1,
    height: 1,
    format: "rgba",
    data: "/wAA/w==",
  }],
  placements: [{
    image_id: 9,
    placement_id: 3,
    ordinal: 0,
    x_offset: 0,
    y_offset: 0,
    source_x: 0,
    source_y: 0,
    source_width: 1,
    source_height: 1,
    columns: 1,
    rows: 1,
    grid_cols: 1,
    grid_rows: 1,
    pixel_width: 8,
    pixel_height: 16,
    viewport_col: 0,
    viewport_row: 0,
    viewport_visible: true,
    z: 0,
  }],
};

test("attachSurface render mode yields Kitty pixels and placements with render events", async () => {
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
      graphics: renderGraphics,
    });
    transport.emit({ id: request.id, ok: true, data: {} });
    transport.emit({
      event: "render-delta",
      surface: 7,
      cursor: { x: 0, y: 0, style: "bar", blink: false, visible: false, color: "#ffffff" },
      full: false,
      scrollback_rows: 43,
      rows: [{ row: 0, runs: [{ text: "ok ", fg: "#00ff00", bg: null, attrs: 0 }] }],
      graphics: {
        generation: 4n,
        removed_image_ids: [99],
        placements: [{ ...renderGraphics.placements[0], viewport_col: 1 }],
      },
    });
    transport.emit({
      event: "render-delta",
      surface: 7,
      cursor: { x: 0, y: 0, style: "bar", blink: false, visible: false, color: null },
      full: false,
      rows: [],
      graphics: {
        generation: 5n,
        images: [{ ...renderGraphics.images[0], generation: 3n }],
      },
    });
  });
  const client = new CmuxClient({
    transport: main,
    streamTransportFactory: () => attach,
    timeoutMs: 100,
  });

  assert.equal((await client.identify()).protocol, 7);
  assert.equal(client.protocol, 7);
  const stream = await client.attachSurface(7n, { mode: "render", cols: 120, rows: 40 });
  assert.equal(identifyRequests, 1);
  assert.deepEqual(await stream.next(), {
    event: "render-state",
    surface: 7n,
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
    graphics: renderGraphics,
  });
  assert.deepEqual(await stream.next(), {
    event: "render-delta",
    surface: 7n,
    cursor: { x: 0, y: 0, style: "bar", blink: false, visible: false, color: "#ffffff" },
    full: false,
    scrollback_rows: 43,
    rows: [{ row: 0, runs: [{ text: "ok ", fg: "#00ff00", bg: null, attrs: 0 }] }],
    graphics: {
      generation: 4n,
      removed_image_ids: [99],
      placements: [{ ...renderGraphics.placements[0], viewport_col: 1 }],
    },
  });
  assert.deepEqual(await stream.next(), {
    event: "render-delta",
    surface: 7n,
    cursor: { x: 0, y: 0, style: "bar", blink: false, visible: false, color: null },
    full: false,
    rows: [],
    graphics: {
      generation: 5n,
      images: [{ ...renderGraphics.images[0], generation: 3n }],
    },
  });
  stream.close();
  await client.close();
});

test("attachSurface render mode rejects oversized Kitty image data before buffering it", async () => {
  const main = new ScriptedTransport((request, transport) => {
    transport.emit({
      id: request.id,
      ok: true,
      data: { app: "cmux-tui", version: "0.1.2", protocol: 7, session: "main", pid: 1 },
    });
  });
  const attach = new ScriptedTransport((request, transport) => {
    transport.emit({
      event: "render-state",
      surface: 7,
      size: { cols: 1, rows: 1 },
      cursor: { x: 0, y: 0, style: "block", blink: false, visible: false, color: null },
      default_fg: "#ffffff",
      default_bg: "#000000",
      scrollback_rows: 0,
      rows: [],
      graphics: {
        ...renderGraphics,
        images: [{ ...renderGraphics.images[0], data: "AAAAA" }],
      },
    });
    transport.emit({ id: request.id, ok: true, data: {} });
  });
  const client = new CmuxClient({
    transport: main,
    streamTransportFactory: () => attach,
    timeoutMs: 100,
    maxAttachEncodedChars: 4,
  } as CmuxClientOptionsWithSecurityLimits);

  await assert.rejects(
    () => client.attachSurface(7n, { mode: "render" }),
    /render-state graphics image data exceeds 4 encoded characters/,
  );
  await client.close();
});

test("attachSurface render mode requires a bounded Kitty placement array", async () => {
  const missingPlacements = {
    generation: renderGraphics.generation,
    images: renderGraphics.images,
  };
  for (const [graphics, expected] of [
    [missingPlacements, /event render-state\.graphics\.placements is required/],
    [{ ...renderGraphics, placements: {} }, /event render-state\.graphics\.placements must be an array/],
    [
      {
        ...renderGraphics,
        placements: new Array(RENDER_GRAPHIC_MAX_PLACEMENTS + 1)
          .fill(renderGraphics.placements[0]),
      },
      new RegExp(`render-state graphics exceeds ${RENDER_GRAPHIC_MAX_PLACEMENTS} placements`),
    ],
  ]) {
    const main = new ScriptedTransport((request, transport) => {
      transport.emit({
        id: request.id,
        ok: true,
        data: { app: "cmux-tui", version: "0.1.2", protocol: 7, session: "main", pid: 1 },
      });
    });
    const attach = new ScriptedTransport((request, transport) => {
      transport.emit({
        event: "render-state",
        surface: 7,
        size: { cols: 1, rows: 1 },
        cursor: { x: 0, y: 0, style: "block", blink: false, visible: false, color: null },
        default_fg: "#ffffff",
        default_bg: "#000000",
        scrollback_rows: 0,
        rows: [],
        graphics,
      });
      transport.emit({ id: request.id, ok: true, data: {} });
    });
    const client = new CmuxClient({
      transport: main,
      streamTransportFactory: () => attach,
      timeoutMs: 100,
    });

    await assert.rejects(
      () => client.attachSurface(7n, { mode: "render" }),
      expected as RegExp,
    );
    await client.close();
  }
});

test("attachSurface render mode requires a bounded Kitty image array", async () => {
  const main = new ScriptedTransport((request, transport) => {
    transport.emit({
      id: request.id,
      ok: true,
      data: { app: "cmux-tui", version: "0.1.2", protocol: 7, session: "main", pid: 1 },
    });
  });
  const attach = new ScriptedTransport((request, transport) => {
    transport.emit({
      event: "render-state",
      surface: 7,
      size: { cols: 1, rows: 1 },
      cursor: { x: 0, y: 0, style: "block", blink: false, visible: false, color: null },
      default_fg: "#ffffff",
      default_bg: "#000000",
      scrollback_rows: 0,
      rows: [],
      graphics: {
        ...renderGraphics,
        images: new Array(RENDER_GRAPHIC_MAX_IMAGES + 1).fill(renderGraphics.images[0]),
      },
    });
    transport.emit({ id: request.id, ok: true, data: {} });
  });
  const client = new CmuxClient({
    transport: main,
    streamTransportFactory: () => attach,
    timeoutMs: 100,
  });

  await assert.rejects(
    () => client.attachSurface(7n, { mode: "render" }),
    new RegExp(`render-state graphics exceeds ${RENDER_GRAPHIC_MAX_IMAGES} images`),
  );
  await client.close();
});

test("attachSurface render mode validates bounded removed Kitty image IDs", async () => {
  const cases: Array<[unknown, RegExp]> = [
    [{}, /event render-delta\.graphics\.removed_image_ids must be an array/],
    [
      new Array(RENDER_GRAPHIC_MAX_IMAGES + 1).fill(1),
      new RegExp(
        `render-delta graphics exceeds ${RENDER_GRAPHIC_MAX_IMAGES} removed image IDs`,
      ),
    ],
    [[0], /render-delta graphics removed_image_ids contains an invalid image ID/],
    [[-1], /event render-delta\.graphics\.removed_image_ids\[0\] must be in uint32 range/],
    [[1.5], /event render-delta\.graphics\.removed_image_ids\[0\] must be a safe integer number/],
    [["1"], /event render-delta\.graphics\.removed_image_ids\[0\] must be a safe integer number/],
  ];
  for (const [removedImageIds, expected] of cases) {
    const main = new ScriptedTransport((request, transport) => {
      transport.emit({
        id: request.id,
        ok: true,
        data: { app: "cmux-tui", version: "0.1.2", protocol: 7, session: "main", pid: 1 },
      });
    });
    const attach = new ScriptedTransport((request, transport) => {
      transport.emit({
        event: "render-delta",
        surface: 7,
        cursor: {
          x: 0,
          y: 0,
          style: "block",
          blink: false,
          visible: false,
          color: null,
        },
        full: false,
        rows: [],
        graphics: {
          generation: 2n,
          removed_image_ids: removedImageIds,
        },
      });
      transport.emit({ id: request.id, ok: true, data: {} });
    });
    const client = new CmuxClient({
      transport: main,
      streamTransportFactory: () => attach,
      timeoutMs: 100,
    });

    await assert.rejects(
      () => client.attachSurface(7n, { mode: "render" }),
      expected,
    );
    await client.close();
  }
});

test("render attach counts non-image JSON bytes against the retained buffer cap", async () => {
  const main = new ScriptedTransport((request, transport) => {
    transport.emit({
      id: request.id,
      ok: true,
      data: { app: "cmux-tui", version: "0.1.2", protocol: 7, session: "main", pid: 1 },
    });
  });
  const renderDelta = {
    event: "render-delta",
    surface: 7,
    cursor: { x: 0, y: 0, style: "block", blink: false, visible: false, color: null },
    full: false,
    rows: [{ row: 0, runs: [{ text: "界", fg: null, bg: null, attrs: 0 }] }],
    graphics: {
      generation: 5n,
      removed_image_ids: [9],
      placements: [renderGraphics.placements[0]],
    },
  };
  const encoded = stringifyWireJson(renderDelta);
  const encodedChars = encoded.length;
  assert.ok(new TextEncoder().encode(encoded).byteLength > encodedChars);
  const attach = new ScriptedTransport((request, transport) => {
    transport.emit(renderDelta);
    transport.emit({ id: request.id, ok: true, data: {} });
  });
  const client = new CmuxClient({
    transport: main,
    streamTransportFactory: () => attach,
    timeoutMs: 100,
    maxAttachEncodedChars: encodedChars,
  } as CmuxClientOptionsWithSecurityLimits);

  await assert.rejects(
    () => client.attachSurface(7n, { mode: "render" }),
    new RegExp(`stream event data exceeds ${encodedChars} bytes`),
  );
  await client.close();
});

test("render attach accepts the full decoded-image budget below its encoded limit", async () => {
  assert.equal(RENDER_GRAPHIC_MAX_DECODED_BYTES, 10_000_000);
  assert.equal(RENDER_GRAPHIC_MAX_ENCODED_CHARS, 13_333_336);
  assert.equal(RENDER_GRAPHIC_MAX_IMAGES, 4_096);
  assert.equal(RENDER_GRAPHIC_MAX_PLACEMENTS, 16_384);
  assert.equal(RENDER_ATTACH_MAX_ENCODED_CHARS, 33_554_432);
  assert.equal(DEFAULT_MAX_ATTACH_ENCODED_CHARS, RENDER_ATTACH_MAX_ENCODED_CHARS);
  assert.ok(RENDER_GRAPHIC_MAX_ENCODED_CHARS < RENDER_ATTACH_MAX_ENCODED_CHARS);

  const main = new ScriptedTransport((request, transport) => {
    transport.emit({
      id: request.id,
      ok: true,
      data: { app: "cmux-tui", version: "0.1.2", protocol: 7, session: "main", pid: 1 },
    });
  });
  const encoded = `${"A".repeat(RENDER_GRAPHIC_MAX_ENCODED_CHARS - 2)}==`;
  const attach = new ScriptedTransport((request, transport) => {
    transport.emit({
      event: "render-state",
      surface: 7,
      size: { cols: 1, rows: 1 },
      cursor: { x: 0, y: 0, style: "block", blink: false, visible: false, color: null },
      default_fg: "#ffffff",
      default_bg: "#000000",
      scrollback_rows: 0,
      rows: [],
      graphics: {
        generation: 1n,
        images: [{
          id: 1,
          generation: 1n,
          width: RENDER_GRAPHIC_MAX_DECODED_BYTES / 4,
          height: 1,
          format: "rgba",
          data: encoded,
        }],
        placements: [],
      },
    });
    transport.emit({ id: request.id, ok: true, data: {} });
  });
  const client = new CmuxClient({
    transport: main,
    streamTransportFactory: () => attach,
    timeoutMs: 1_000,
  });

  await client.identify();
  const stream = await client.attachSurface(7n, { mode: "render" });
  const event = await stream.next() as RenderStateEvent;
  assert.equal(
    event.graphics?.images?.[0]?.data.length,
    RENDER_GRAPHIC_MAX_ENCODED_CHARS,
  );
  stream.close();
  await client.close();
});

test("render attach rejects an image above its protocol limit under the larger attach cap", async () => {
  const main = new ScriptedTransport((request, transport) => {
    transport.emit({
      id: request.id,
      ok: true,
      data: { app: "cmux-tui", version: "0.1.2", protocol: 7, session: "main", pid: 1 },
    });
  });
  const attach = new ScriptedTransport((request, transport) => {
    transport.emit({
      event: "render-state",
      surface: 7,
      size: { cols: 1, rows: 1 },
      cursor: { x: 0, y: 0, style: "block", blink: false, visible: false, color: null },
      default_fg: "#ffffff",
      default_bg: "#000000",
      scrollback_rows: 0,
      rows: [],
      graphics: {
        generation: 1n,
        images: [{
          id: 1,
          generation: 1n,
          width: 1,
          height: 1,
          format: "rgba",
          data: "A".repeat(RENDER_GRAPHIC_MAX_ENCODED_CHARS + 1),
        }],
        placements: [],
      },
    });
    transport.emit({ id: request.id, ok: true, data: {} });
  });
  const client = new CmuxClient({
    transport: main,
    streamTransportFactory: () => attach,
    timeoutMs: 1_000,
  });

  await assert.rejects(
    () => client.attachSurface(7n, { mode: "render" }),
    new RegExp(
      `render-state graphics image data exceeds ${RENDER_GRAPHIC_MAX_ENCODED_CHARS} encoded characters`,
    ),
  );
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
  const stream = await client.attachSurface(7n, { mode: "render" });
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
    client.attachSurface(7n, { mode: "render" }),
    (error: unknown) => error instanceof CmuxProtocolError
      && error.message === "render attach requires protocol 7 or newer; server reported protocol 6",
  );
  assert.equal(attachRequests, 0);
  const bytes = await client.attachSurface(7n);
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
    () => client.attachSurface(7n, { cols: 80, rows: 24 }),
    (error: unknown) => error instanceof CmuxProtocolError
      && error.message === "attach-surface.cols requires server capability attach-initial-size",
  );
  assert.equal(attachRequests, 0);
  await client.close();
});

test("attachSurface rejects partial initial sizing before transport", async () => {
  let requests = 0;
  const transport = new ScriptedTransport(() => { requests += 1; });
  const client = new CmuxClient({ transport, timeoutMs: 100 });

  await assert.rejects(
    () => client.attachSurface(7n, { cols: 80 } as never),
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
    () => client.closeWorkspaceRegistry({ key: "stable", expected_revision: 4n }),
    (error: unknown) => error instanceof CmuxProtocolError
      && error.message === "workspace registry is not supported by this server",
  );
  assert.equal(mutationRequests, 0);
  await client.close();
});

test("generic request preserves exact wire command and typed result", async () => {
  let sent: Record<string, unknown> | undefined;
  const transport = new ScriptedTransport((request, connection) => {
    if (request.cmd === "identify") {
      connection.emit({
        id: request.id,
        ok: true,
        data: { app: "cmux-tui", version: "0.1.2", protocol: 6, session: "main", pid: 1 },
      });
      return;
    }
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
  assert.deepEqual(sent, { id: 2, cmd: "ping" });
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
    {
      workspace: 1,
      key: "stable",
      index: 0,
      workspace_revision: 5,
      replayed: false,
      registry_id: "registry",
      generation: "generation",
    },
    {
      surface: 4,
      terminal_id: "00000000000040008000000000000001",
      terminal_incarnation: null,
      pane: 3,
      screen: 2,
      workspace: 1,
      key: "stable",
      lifecycle: "running",
      exit: null,
      terminal_revision: 1,
      already_exited: false,
      replayed: false,
      registry_id: "registry",
      generation: "generation",
    },
    {
      workspace: 1,
      key: "stable",
      index: 0,
      workspace_revision: 6,
      replayed: false,
      registry_id: "registry",
      generation: "generation",
    },
    {
      workspace: 1,
      key: "stable",
      index: 0,
      workspace_revision: 7,
      replayed: false,
      registry_id: "registry",
      generation: "generation",
    },
    {
      workspace: 1,
      key: "stable",
      index: 0,
      workspace_revision: 8,
      replayed: false,
      registry_id: "registry",
      generation: "generation",
    },
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

  assert.equal((await client.createWorkspace({ name: "gui", key: "stable", expected_revision: 4n })).workspace_revision, 5n);
  assert.equal((await client.createTerminal({ key: "stable", command: "echo ready" })).surface, 4n);
  assert.equal((await client.renameWorkspaceRegistry({ key: "stable", name: "renamed", expected_revision: 5n })).workspace_revision, 6n);
  assert.equal((await client.moveWorkspaceRegistry({ key: "stable", index: 0n, expected_revision: 6n })).workspace_revision, 7n);
  assert.equal((await client.closeWorkspaceRegistry({ key: "stable", expected_revision: 7n })).workspace_revision, 8n);
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

  await client.setSplitRatio(42n, 0.65);

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
    sizes: [{ surface: 31, cols: 126, rows: 38, size_participating: true }],
    self: true,
  }];
  const transport = new ScriptedTransport((request, connection) => {
    if (request.cmd === "identify") {
      connection.emit({
        id: request.id,
        ok: true,
        data: { app: "cmux-tui", version: "0.1.2", protocol: 10, session: "main", pid: 1 },
      });
      return;
    }
    assert.deepEqual(request, { id: 2, cmd: "list-clients" });
    connection.emit({ id: request.id, ok: true, data: response });
  });
  const client = new CmuxClient({ transport });

  assert.deepEqual(await client.listClients(), [{
    ...response[0],
    client: 7n,
    connected_seconds: 12n,
    attached: [31n],
    sizes: [{ ...response[0]!.sizes[0], surface: 31n }],
  }]);
  await client.close();
});

test("setClientSizing serializes client participation", async () => {
  const transport = new ScriptedTransport((request, connection) => {
    if (request.cmd === "identify") {
      connection.emit({
        id: request.id,
        ok: true,
        data: { app: "cmux-tui", version: "0.1.2", protocol: 10, session: "main", pid: 1 },
      });
      return;
    }
    assert.deepEqual(request, {
      id: 2,
      cmd: "set-client-sizing",
      surface: 31,
      client: 7,
      enabled: false,
    });
    connection.emit({ id: request.id, ok: true, data: {} });
  });
  const client = new CmuxClient({ transport });

  await client.setClientSizing(31n, 7n, false);
  await client.close();
});

test("setClientSizing rejects servers older than protocol 10", async () => {
  const transport = new ScriptedTransport((request, connection) => {
    assert.equal(request.cmd, "identify");
    connection.emit({
      id: request.id,
      ok: true,
      data: { app: "cmux-tui", version: "0.1.2", protocol: 9, session: "main", pid: 1 },
    });
  });
  const client = new CmuxClient({ transport, timeoutMs: 100 });

  await assert.rejects(client.setClientSizing(31n, 7n, false), /set-client-sizing requires protocol 10/);
  await client.close();
});

test("client sizing modes serialize as one atomic command", async () => {
  const expected = [
    { id: 2, cmd: "set-client-sizing", surface: 31, client: 7, enabled: true, exclusive: true },
    { id: 3, cmd: "set-client-sizing", surface: 31, enabled: true },
  ];
  const transport = new ScriptedTransport((request, connection) => {
    if (request.cmd === "identify") {
      connection.emit({
        id: request.id,
        ok: true,
        data: { app: "cmux-tui", version: "0.1.2", protocol: 10, session: "main", pid: 1 },
      });
      return;
    }
    assert.deepEqual(request, expected.shift());
    connection.emit({ id: request.id, ok: true, data: {} });
  });
  const client = new CmuxClient({ transport });

  await client.useOnlyClientSizing(31n, 7n);
  await client.useAllClientSizing(31n);
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
    if (request.cmd === "identify") {
      connection.emit({
        id: request.id,
        ok: true,
        data: { app: "cmux-tui", version: "0.1.2", protocol: 7, session: "main", pid: 1 },
      });
      return;
    }
    assert.deepEqual(request, { id: 2, cmd: "read-scrollback", surface: 7, start: 40, count: 1 });
    connection.emit({ id: request.id, ok: true, data: response });
  });
  const client = new CmuxClient({ transport });

  assert.deepEqual(await client.readScrollback(7n, 40, 1), response);
  await client.close();
});

test("send serializes base64 input and the protocol v7 paste flag", async () => {
  const transport = new ScriptedTransport((request, connection) => {
    if (request.cmd === "identify") {
      connection.emit({
        id: request.id,
        ok: true,
        data: { app: "cmux-tui", version: "0.1.2", protocol: 7, session: "main", pid: 1 },
      });
      return;
    }
    assert.deepEqual(request, {
      id: 2,
      cmd: "send",
      surface: 7,
      text: "hello",
      bytes: "AAEC",
      paste: true,
    });
    connection.emit({ id: request.id, ok: true, data: {} });
  });
  const client = new CmuxClient({ transport });

  await client.send(7n, { text: "hello", base64: "AAEC", paste: true });
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

  await assert.rejects(client.readScrollback(7n, 0, 1), CmuxCommandError);
  await assert.rejects(client.send(7n, { text: "hello", paste: true }), CmuxCommandError);
  await assert.rejects(client.subscribe({ treeEvents: "deltas" }), CmuxCommandError);
  await client.close();
});

test("subscribe yields client attached, changed, and detached events", async () => {
  const transport = new ScriptedTransport((request, connection) => {
    if (request.cmd === "identify") {
      assert.deepEqual(request, { id: 1, cmd: "identify" });
      connection.emit({ id: request.id, ok: true, data: identifyResult(6) });
      return;
    }
    assert.deepEqual(request, { id: 2, cmd: "subscribe" });
    connection.emit({ event: "client-attached", client: 2, transport: "ws", name: "phone", kind: "web" });
    connection.emit({ id: request.id, ok: true, data: {} });
    connection.emit({ event: "client-changed", client: 2, name: "tablet", kind: "web" });
    connection.emit({ event: "client-detached", client: 2 });
  });
  const client = new CmuxClient({ transport, timeoutMs: 100 });

  const events = await client.subscribe();
  assert.deepEqual(await events.next(), {
    event: "client-attached",
    client: 2n,
    transport: "ws",
    name: "phone",
    kind: "web",
  });
  assert.deepEqual(await events.next(), { event: "client-changed", client: 2n, name: "tablet", kind: "web" });
  assert.deepEqual(await events.next(), { event: "client-detached", client: 2n });
  events.close();
  await client.close();
});

test("subscribe validates gated known events against the negotiated protocol", async () => {
  const legacyTransport = new ScriptedTransport((request, connection) => {
    if (request.cmd === "identify") {
      connection.emit({ id: request.id, ok: true, data: identifyResult(6) });
      return;
    }
    connection.emit({
      event: "surface-resized",
      surface: 7,
      cols: 80,
      rows: 24,
    });
    connection.emit({ id: request.id, ok: true, data: {} });
  });
  const legacy = new CmuxClient({ transport: legacyTransport, timeoutMs: 100 });
  const events = await legacy.subscribe();
  assert.deepEqual(await events.next(), {
    event: "surface-resized",
    surface: 7n,
    cols: 80,
    rows: 24,
  });
  events.close();
  await legacy.close();

  const currentTransport = new ScriptedTransport((request, connection) => {
    if (request.cmd === "identify") {
      connection.emit({ id: request.id, ok: true, data: identifyResult(7) });
      return;
    }
    connection.emit({
      event: "surface-resized",
      surface: 7,
      cols: 80,
      rows: 24,
    });
    connection.emit({ id: request.id, ok: true, data: {} });
  });
  const current = new CmuxClient({ transport: currentTransport, timeoutMs: 100 });
  await assert.rejects(
    () => current.subscribe(),
    /event surface-resized\.reservation_id is required/,
  );
  await current.close();
});

test("concurrent shared subscriptions require dedicated transports", async () => {
  const transport = new ScriptedTransport((request, connection) => {
    if (request.cmd === "identify") {
      connection.emit({ id: request.id, ok: true, data: identifyResult(6) });
      return;
    }
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
    surface: 4n,
    kind: "pty" as const,
    browser_source: null,
    name: "shell",
    title: "shell",
    size: { cols: 80, rows: 24 },
    dead: false,
  };
  const pane = { id: 3n, name: null, active_tab: 0n, tabs: [tab] };
  const screen = {
    id: 2n,
    name: null,
    active: true,
    active_pane: 3n,
    zoomed_pane: null,
    layout: { type: "leaf" as const, pane: 3n },
    panes: [pane],
  };
  const workspace = { id: 1n, key: "stable", name: "sdk", active: true, screens: [screen] };
  const deltas: TreeDeltaEvent[] = [
    { event: "workspace-added", registry_id: "registry", generation: "generation", workspace: 1n, index: 0n, workspace_revision: 1n, entity: workspace },
    { event: "workspace-closed", registry_id: "registry", generation: "generation", workspace: 1n, index: 0n, workspace_revision: 4n, entity: workspace },
    { event: "workspace-renamed", registry_id: "registry", generation: "generation", workspace: 1n, workspace_revision: 2n, entity: workspace },
    { event: "workspace-moved", registry_id: "registry", generation: "generation", workspace: 1n, index: 0n, workspace_revision: 3n, entity: workspace },
    { event: "screen-added", workspace: 1n, screen: 2n, index: 0n, entity: screen },
    { event: "screen-closed", workspace: 1n, screen: 2n, index: 0n, entity: screen },
    { event: "screen-renamed", workspace: 1n, screen: 2n, entity: screen },
    { event: "pane-added", workspace: 1n, screen: 2n, pane: 3n, index: 0n, entity: pane },
    { event: "pane-closed", workspace: 1n, screen: 2n, pane: 3n, index: 0n, entity: pane },
    { event: "tab-added", workspace: 1n, screen: 2n, pane: 3n, surface: 4n, index: 0n, entity: tab },
    { event: "tab-closed", workspace: 1n, screen: 2n, pane: 3n, surface: 4n, index: 0n, entity: tab },
    { event: "tab-renamed", workspace: 1n, screen: 2n, pane: 3n, surface: 4n, entity: tab },
  ];
  const transport = new ScriptedTransport((request, connection) => {
    if (request.cmd === "identify") {
      connection.emit({
        id: request.id,
        ok: true,
        data: { app: "cmux-tui", version: "0.1.2", protocol: 7, session: "main", pid: 1 },
      });
      return;
    }
    assert.deepEqual(request, { id: 2, cmd: "subscribe", tree_events: "deltas" });
    for (const event of deltas) connection.emit(event as unknown as Record<string, unknown>);
    connection.emit({ id: request.id, ok: true, data: {} });
  });
  const client = new CmuxClient({ transport, timeoutMs: 100 });

  const events = await client.subscribe({ treeEvents: "deltas" });
  for (const expected of deltas) assert.deepEqual(await events.next(), expected);
  events.close();
  await client.close();
});
