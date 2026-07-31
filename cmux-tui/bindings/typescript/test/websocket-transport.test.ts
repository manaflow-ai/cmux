import assert from "node:assert/strict";
import test from "node:test";
import {
  Client,
  CmuxAbortError,
  CmuxConnectionError,
  CmuxTimeoutError,
  decimalString,
  sessionId,
  terminalId,
  workspaceId,
} from "../src/index.js";
import {
  WebSocketTransport,
  type WebSocketConstructor,
  type WebSocketLike,
} from "../src/raw/websocket-transport.js";
import {
  WebSocketTransport as ResourceWebSocketTransport,
  type WebSocketConstructor as ResourceWebSocketConstructor,
} from "../src/websocket-transport.js";

class FakeWebSocket implements WebSocketLike {
  static readonly instances: FakeWebSocket[] = [];
  readonly sent: string[] = [];
  readonly url: string;
  readonly protocols?: string | string[];
  readyState = 0;
  closeCalls = 0;
  delayCloseEvent = false;
  sendFailure: ((data: string) => Error | undefined) | undefined;
  private pendingCloseEvent: { code?: number; reason?: string } | undefined;
  private readonly listeners = new Map<string, Set<(event: unknown) => void>>();

  constructor(url: string | URL, protocols?: string | string[]) {
    this.url = String(url);
    this.protocols = protocols;
    FakeWebSocket.instances.push(this);
  }

  send(data: string): void {
    const failure = this.sendFailure?.(data);
    if (failure) throw failure;
    this.sent.push(data);
  }
  close(code?: number, reason?: string): void {
    this.closeCalls += 1;
    this.readyState = 2;
    this.pendingCloseEvent = { code, reason };
    if (!this.delayCloseEvent) this.finishClose();
  }
  finishClose(): void {
    this.readyState = 3;
    const event = this.pendingCloseEvent ?? {};
    this.pendingCloseEvent = undefined;
    this.emit("close", event);
  }
  rejectAuthentication(): void {
    this.readyState = 3;
    this.emit("close", { code: 1008, reason: "authentication failed" });
  }
  addEventListener(type: string, listener: (event: never) => void): void {
    const listeners = this.listeners.get(type) ?? new Set();
    listeners.add(listener as (event: unknown) => void);
    this.listeners.set(type, listeners);
  }
  removeEventListener(type: string, listener: (event: never) => void): void {
    this.listeners.get(type)?.delete(listener as (event: unknown) => void);
  }
  open(): void { this.readyState = 1; this.emit("open", {}); }
  message(data: unknown): void { this.emit("message", { data }); }
  error(error: Error): void { this.emit("error", { error }); }
  private emit(type: string, event: unknown): void {
    for (const listener of this.listeners.get(type) ?? []) listener(event);
  }
}

const Constructor = FakeWebSocket as unknown as WebSocketConstructor;
const ResourceConstructor =
  FakeWebSocket as unknown as ResourceWebSocketConstructor;
const RESOURCE_SESSION = sessionId(`session_${"a".repeat(32)}`);
const RESOURCE_WORKSPACE = workspaceId(`ws_${"b".repeat(32)}`);
const RESOURCE_TERMINAL = terminalId(`term_${"c".repeat(32)}`);

function resourceOperationCount(socket: FakeWebSocket, operation: string): number {
  return socket.sent.filter((json) => {
    try {
      return (JSON.parse(json) as { operation?: unknown }).operation === operation;
    } catch {
      return false;
    }
  }).length;
}

test("WebSocketTransport pairs before flushing queued protocol frames", () => {
  const challenges: string[] = [];
  const challengeIds: bigint[] = [];
  const credentials: string[] = [];
  const transport = new WebSocketTransport("ws://localhost/cmux", { WebSocket: Constructor, protocols: "cmux" });
  const socket = FakeWebSocket.instances.at(-1)!;
  transport.onError(() => undefined);
  transport.send('{"id":1,"cmd":"ping"}');
  assert.deepEqual(socket.sent, []);
  socket.open();
  assert.deepEqual(socket.sent, ['{"pair":{"request":true}}']);
  transport.close();

  const approved = new WebSocketTransport("ws://localhost/cmux", {
    WebSocket: Constructor,
    onPairingChallenge: (challenge) => {
      challengeIds.push(challenge.id);
      challenges.push(challenge.code);
    },
    onPairingCredential: (credential) => credentials.push(credential),
  });
  const approvedSocket = FakeWebSocket.instances.at(-1)!;
  approved.send('{"id":1,"cmd":"ping"}');
  approvedSocket.open();
  approvedSocket.message('{"pairing":{"id":7,"code":"123 456","peer":"127.0.0.1","expires_in":60}}');
  assert.deepEqual(challenges, ["123 456"]);
  assert.deepEqual(challengeIds, [7n]);
  approvedSocket.message('{"paired":{"credential":"issued-secret"}}');
  assert.deepEqual(credentials, ["issued-secret"]);
  assert.deepEqual(approvedSocket.sent, [
    '{"pair":{"request":true}}',
    '{"id":1,"cmd":"ping"}',
  ]);
  assert.equal(socket.url, "ws://localhost/cmux");
  assert.equal(socket.protocols, "cmux");
  approved.close();
});

test("WebSocketTransport sends the optional auth preamble before queued requests", () => {
  const transport = new WebSocketTransport("ws://localhost/cmux", {
    WebSocket: Constructor,
    authToken: "secret-token",
  });
  const socket = FakeWebSocket.instances.at(-1)!;
  transport.send('{"id":1,"cmd":"identify"}');
  socket.open();
  assert.deepEqual(socket.sent, [
    '{"auth":{"token":"secret-token"}}',
    '{"id":1,"cmd":"identify"}',
  ]);
  transport.close();
});

test("WebSocketTransport reports a rejected credential", () => {
  let rejected = 0;
  const transport = new WebSocketTransport("ws://localhost/cmux", {
    WebSocket: Constructor,
    authToken: "expired",
    onAuthenticationRejected: () => rejected += 1,
  });
  const socket = FakeWebSocket.instances.at(-1)!;
  socket.open();
  socket.rejectAuthentication();
  assert.equal(rejected, 1);
  transport.close();
});

test("WebSocketTransport forwards text, errors, and close", () => {
  const transport = new WebSocketTransport("ws://localhost/cmux", {
    WebSocket: Constructor,
    authToken: "test",
  });
  const socket = FakeWebSocket.instances.at(-1)!;
  const messages: string[] = [];
  const errors: Error[] = [];
  let closes = 0;
  transport.onMessage((message) => messages.push(message));
  transport.onError((error) => errors.push(error));
  transport.onClose(() => closes += 1);
  socket.open();
  socket.message('{"event":"tree-changed"}');
  socket.error(new Error("boom"));
  socket.close();
  assert.deepEqual(messages, ['{"event":"tree-changed"}']);
  assert.equal(errors[0]?.message, "boom");
  assert.equal(closes, 1);
});

test("WebSocketTransport rejects binary frames", () => {
  const transport = new WebSocketTransport("ws://localhost/cmux", {
    WebSocket: Constructor,
    authToken: "test",
  });
  const socket = FakeWebSocket.instances.at(-1)!;
  const errors: Error[] = [];
  transport.onError((error) => errors.push(error));
  socket.open();
  socket.message(Uint8Array.from([1, 2, 3]));
  assert.match(errors[0]?.message ?? "", /non-text frame/);
  transport.close();
});

test("WebSocketTransport bounds queued and inbound messages", () => {
  const queued = new WebSocketTransport("ws://localhost/cmux", {
    WebSocket: Constructor,
    authToken: "test",
    maxPendingMessages: 1,
  });
  queued.send("{}");
  assert.throws(() => queued.send("{}"), /buffer is full/);
  queued.close();

  const inbound = new WebSocketTransport("ws://localhost/cmux", {
    WebSocket: Constructor,
    authToken: "test",
    maxInboundMessageBytes: 8,
  });
  const socket = FakeWebSocket.instances.at(-1)!;
  const errors: Error[] = [];
  inbound.onError((error) => errors.push(error));
  socket.open();
  socket.message('{"123":9}');
  assert.match(errors[0]?.message ?? "", /exceeds 8 bytes/);
  assert.equal(socket.readyState, 3);
});

test("resource WebSocket transport pairs before flushing requests", () => {
  const challenges: Array<{ code: string; peer: string; expiresIn: number }> = [];
  const credentials: string[] = [];
  const transport = new ResourceWebSocketTransport("ws://localhost/cmux", {
    WebSocket: ResourceConstructor,
    onPairingChallenge: ({ code, peer, expiresIn }) => {
      challenges.push({ code, peer, expiresIn });
    },
    onPairingCredential: (credential) => credentials.push(credential),
  });
  const socket = FakeWebSocket.instances.at(-1)!;
  transport.send('{"protocol":"cmux.protocol/1","type":"request"}');
  socket.open();
  assert.deepEqual(socket.sent, ['{"pair":{"request":true}}']);
  socket.message(
    '{"pairing":{"id":9,"code":"654 321","peer":"127.0.0.1","expires_in":60}}',
  );
  assert.deepEqual(challenges, [
    { code: "654 321", peer: "127.0.0.1", expiresIn: 60 },
  ]);
  assert.deepEqual(socket.sent, ['{"pair":{"request":true}}']);
  socket.message('{"paired":{"credential":"resource-secret"}}');
  assert.deepEqual(credentials, ["resource-secret"]);
  assert.deepEqual(socket.sent, [
    '{"pair":{"request":true}}',
    '{"protocol":"cmux.protocol/1","type":"request"}',
  ]);
  transport.close();
});

for (const preamble of [
  { name: "pairing", authToken: undefined, frame: '"pair"' },
  { name: "authentication", authToken: "secret", frame: '"auth"' },
] as const) {
  test(`resource WebSocket ${preamble.name} preamble failure closes and settles`, async () => {
    const credentials: string[] = [];
    const errors: Error[] = [];
    let closes = 0;
    const transport = new ResourceWebSocketTransport("ws://localhost/cmux", {
      WebSocket: ResourceConstructor,
      authToken: preamble.authToken,
      onPairingCredential: (credential) => credentials.push(credential),
    });
    const client = new Client({ transport, timeoutMs: 0 });
    const socket = FakeWebSocket.instances.at(-1)!;
    socket.sendFailure = (data) => data.includes(preamble.frame)
      ? new Error(`${preamble.name} preamble exploded`)
      : undefined;
    transport.onError((error) => errors.push(error));
    transport.onClose(() => closes += 1);
    const ping = client.session(RESOURCE_SESSION).ping();
    const rejected = assert.rejects(() => ping, CmuxConnectionError);

    try {
      assert.doesNotThrow(() => socket.open());
      assert.deepEqual(socket.sent, []);
      assert.match(
        errors[0]?.message ?? "",
        new RegExp(`WebSocket ${preamble.name} preamble failed.*preamble exploded`),
      );
      assert.equal(errors.length, 1);
      assert.equal(closes, 1);
      assert.equal(socket.readyState, 3);
      assert.deepEqual(credentials, []);
      await Promise.race([
        rejected,
        new Promise<never>((_resolve, reject) => {
          setTimeout(() => reject(new Error("request remained pending")), 50);
        }),
      ]);
    } finally {
      client.close();
      await rejected;
    }
  });
}

for (const preamble of [
  { name: "pairing", authToken: undefined, frame: '"pair"' },
  { name: "authentication", authToken: "secret", frame: '"auth"' },
] as const) {
  test(`resource WebSocket ${preamble.name} failure ignores late pairing while closing`, async () => {
    const credentials: string[] = [];
    const errors: Error[] = [];
    let closes = 0;
    const transport = new ResourceWebSocketTransport("ws://localhost/cmux", {
      WebSocket: ResourceConstructor,
      authToken: preamble.authToken,
      onPairingCredential: (credential) => credentials.push(credential),
    });
    const client = new Client({ transport, timeoutMs: 0 });
    const socket = FakeWebSocket.instances.at(-1)!;
    socket.delayCloseEvent = true;
    socket.sendFailure = (data) => data.includes(preamble.frame)
      ? new Error(`${preamble.name} preamble exploded`)
      : undefined;
    transport.onError((error) => errors.push(error));
    transport.onClose(() => closes += 1);
    transport.send("direct-queued");
    const ping = client.session(RESOURCE_SESSION).ping();
    const rejected = assert.rejects(() => ping, CmuxConnectionError);

    try {
      socket.open();
      assert.equal(socket.readyState, 2);
      assert.equal(closes, 0);

      socket.message('{"paired":{"credential":"late-secret"}}');
      assert.deepEqual(credentials, []);
      assert.throws(() => transport.send("after-failure"), /closed/);

      socket.sendFailure = undefined;
      socket.open();
      assert.deepEqual(socket.sent, []);
      assert.equal(errors.length, 1);
      assert.equal(socket.closeCalls, 1);

      socket.finishClose();
      socket.finishClose();
      assert.equal(closes, 1);
      await rejected;
    } finally {
      client.close();
      await rejected;
    }
  });
}

test("resource WebSocket drops a request that expires before pairing", async () => {
  const transport = new ResourceWebSocketTransport("ws://localhost/cmux", {
    WebSocket: ResourceConstructor,
  });
  const client = new Client({ transport, timeoutMs: 10 });
  const socket = FakeWebSocket.instances.at(-1)!;
  const ping = client.session(RESOURCE_SESSION).ping();

  socket.open();
  assert.deepEqual(socket.sent, ['{"pair":{"request":true}}']);
  await assert.rejects(() => ping, CmuxTimeoutError);

  socket.message('{"paired":{"credential":"resource-secret"}}');
  assert.deepEqual(socket.sent, ['{"pair":{"request":true}}']);
  client.close();
});

test("resource WebSocket drops a stream open that expires before pairing", async () => {
  const transport = new ResourceWebSocketTransport("ws://localhost/cmux", {
    WebSocket: ResourceConstructor,
  });
  const client = new Client({
    transport,
    timeoutMs: 10,
    randomHex128: () => "c".repeat(32),
  });
  const socket = FakeWebSocket.instances.at(-1)!;
  const opening = client.session(RESOURCE_SESSION).events();

  socket.open();
  await assert.rejects(() => opening, CmuxTimeoutError);
  socket.message('{"paired":{"credential":"resource-secret"}}');

  assert.deepEqual(socket.sent, ['{"pair":{"request":true}}']);
  client.close();
});

test("resource WebSocket keeps a queued mutation timeout determinate", async () => {
  const transport = new ResourceWebSocketTransport("ws://localhost/cmux", {
    WebSocket: ResourceConstructor,
  });
  const client = new Client({
    transport,
    randomHex128: () => "d".repeat(32),
  });
  const socket = FakeWebSocket.instances.at(-1)!;
  const renaming = client
    .session(RESOURCE_SESSION)
    .workspace(RESOURCE_WORKSPACE)
    .rename("queued", { timeoutMs: 10 });

  socket.open();
  await assert.rejects(() => renaming, CmuxTimeoutError);
  socket.message('{"paired":{"credential":"resource-secret"}}');

  assert.deepEqual(socket.sent, ['{"pair":{"request":true}}']);
  client.close();
});

test("resource WebSocket keeps a queued mutation abort determinate", async () => {
  const transport = new ResourceWebSocketTransport("ws://localhost/cmux", {
    WebSocket: ResourceConstructor,
  });
  const client = new Client({
    transport,
    randomHex128: () => "e".repeat(32),
  });
  const socket = FakeWebSocket.instances.at(-1)!;
  const controller = new AbortController();
  const renaming = client
    .session(RESOURCE_SESSION)
    .workspace(RESOURCE_WORKSPACE)
    .rename("queued", { signal: controller.signal });

  socket.open();
  controller.abort();
  await assert.rejects(() => renaming, CmuxAbortError);
  socket.message('{"paired":{"credential":"resource-secret"}}');

  assert.deepEqual(socket.sent, ['{"pair":{"request":true}}']);
  client.close();
});

test("resource WebSocket flushes queued frames before a reentrant paired callback", () => {
  let transport!: ResourceWebSocketTransport;
  transport = new ResourceWebSocketTransport("ws://localhost/cmux", {
    WebSocket: ResourceConstructor,
    onPairingCredential: () => transport.send("callback"),
  });
  const socket = FakeWebSocket.instances.at(-1)!;
  transport.send("first");
  transport.send("second");

  socket.open();
  socket.message('{"paired":{"credential":"resource-secret"}}');

  assert.deepEqual(socket.sent, [
    '{"pair":{"request":true}}',
    "first",
    "second",
    "callback",
  ]);
  transport.close();
});

test("resource WebSocket flush preserves FIFO across dispatch callback sends", () => {
  const transport = new ResourceWebSocketTransport("ws://localhost/cmux", {
    WebSocket: ResourceConstructor,
  });
  const socket = FakeWebSocket.instances.at(-1)!;
  transport.sendCancellable("first", () => transport.send("reentrant"));
  transport.send("second");

  socket.open();
  socket.message('{"paired":{"credential":"resource-secret"}}');

  assert.deepEqual(socket.sent, [
    '{"pair":{"request":true}}',
    "first",
    "second",
    "reentrant",
  ]);
  transport.close();
});

test("resource WebSocket send failure during paired flush closes and settles", async () => {
  const credentials: string[] = [];
  const errors: Error[] = [];
  let closes = 0;
  const transport = new ResourceWebSocketTransport("ws://localhost/cmux", {
    WebSocket: ResourceConstructor,
    onPairingCredential: (credential) => credentials.push(credential),
  });
  const client = new Client({ transport, timeoutMs: 0 });
  const socket = FakeWebSocket.instances.at(-1)!;
  transport.onError((error) => errors.push(error));
  transport.onClose(() => closes += 1);
  const ping = client.session(RESOURCE_SESSION).ping();
  const rejected = assert.rejects(() => ping, CmuxConnectionError);

  try {
    socket.open();
    socket.sendFailure = (data) => data.includes('"operation":"session.ping"')
      ? new Error("queued send exploded")
      : undefined;
    assert.doesNotThrow(() => {
      socket.message('{"paired":{"credential":"resource-secret"}}');
    });

    assert.deepEqual(credentials, ["resource-secret"]);
    assert.match(errors[0]?.message ?? "", /dispatch failed.*queued send exploded/);
    assert.equal(socket.readyState, 3);
    assert.equal(closes, 1);
    await Promise.race([
      rejected,
      new Promise<never>((_resolve, reject) => {
        setTimeout(() => reject(new Error("request remained pending")), 50);
      }),
    ]);
  } finally {
    client.close();
    await rejected;
  }
});

test("resource WebSocket fans out throwing observers before socket cleanup rethrows", () => {
  const calls: string[] = [];
  const transport = new ResourceWebSocketTransport("ws://localhost/cmux", {
    WebSocket: ResourceConstructor,
    authToken: "test",
  });
  const socket = FakeWebSocket.instances.at(-1)!;
  transport.onError(() => {
    calls.push("error-one");
    throw new Error("first error observer failed");
  });
  transport.onError(() => calls.push("error-two"));
  transport.onClose(() => {
    calls.push("close-one");
    throw new Error("first close observer failed");
  });
  transport.onClose(() => calls.push("close-two"));
  socket.open();

  assert.throws(
    () => socket.message(Uint8Array.from([1, 2, 3])),
    /first error observer failed/,
  );
  assert.deepEqual(calls, ["error-one", "error-two", "close-one", "close-two"]);
  assert.equal(socket.readyState, 3);
});

test("resource WebSocket wait leases remain reserved until delayed dispatch", async () => {
  const transport = new ResourceWebSocketTransport("ws://localhost/cmux", {
    WebSocket: ResourceConstructor,
  });
  const client = new Client({ transport, timeoutMs: 0 });
  const socket = FakeWebSocket.instances.at(-1)!;
  const terminal = client.session(RESOURCE_SESSION).terminal(RESOURCE_TERMINAL);
  const wait = () => terminal.wait({
    pattern: "never",
    timeoutMs: decimalString("1"),
  });
  socket.open();
  const pending = Array.from({ length: 8 }, wait);
  let afterDispatch: ReturnType<typeof wait> | undefined;

  try {
    await new Promise<void>((resolve) => setTimeout(resolve, 130));
    const ninth = wait();
    pending.push(ninth);
    await assert.rejects(
      Promise.race([
        ninth,
        new Promise<never>((_resolve, reject) => {
          setTimeout(() => reject(new Error("ninth wait was queued")), 20);
        }),
      ]),
      /terminal wait capacity is 8/,
    );

    socket.message('{"paired":{"credential":"resource-secret"}}');
    assert.equal(resourceOperationCount(socket, "terminal.wait"), 8);

    await new Promise<void>((resolve) => setTimeout(resolve, 130));
    afterDispatch = wait();
    assert.equal(resourceOperationCount(socket, "terminal.wait"), 9);
  } finally {
    client.close();
    await Promise.allSettled([
      ...pending,
      ...(afterDispatch ? [afterDispatch] : []),
    ]);
  }
});

test("resource WebSocket preserves paired state when the credential callback throws", () => {
  const transport = new ResourceWebSocketTransport("ws://localhost/cmux", {
    WebSocket: ResourceConstructor,
    onPairingCredential: () => {
      throw new Error("credential sink failed");
    },
  });
  const socket = FakeWebSocket.instances.at(-1)!;
  transport.send("queued");

  socket.open();
  assert.throws(
    () => socket.message('{"paired":{"credential":"resource-secret"}}'),
    /credential sink failed/,
  );
  transport.send("after-callback");

  assert.deepEqual(socket.sent, [
    '{"pair":{"request":true}}',
    "queued",
    "after-callback",
  ]);
  transport.close();
});

test("resource WebSocket publishes close when authentication rejection callback throws", async () => {
  const transport = new ResourceWebSocketTransport("ws://localhost/cmux", {
    WebSocket: ResourceConstructor,
    authToken: "expired",
    onAuthenticationRejected: () => {
      throw new Error("rejection observer failed");
    },
  });
  const client = new Client({ transport, timeoutMs: 0 });
  const socket = FakeWebSocket.instances.at(-1)!;
  const ping = client.session(RESOURCE_SESSION).ping();

  socket.open();
  assert.throws(() => socket.rejectAuthentication(), /rejection observer failed/);
  try {
    await assert.rejects(
      Promise.race([
        ping,
        new Promise<never>((_resolve, reject) => {
          setTimeout(() => reject(new Error("request remained pending")), 50);
        }),
      ]),
      CmuxConnectionError,
    );
  } finally {
    client.close();
  }
});

test("WebSocket resource streams outlive their acknowledged open deadline", async () => {
  const transport = new ResourceWebSocketTransport("ws://localhost/cmux", {
    WebSocket: ResourceConstructor,
    authToken: "test",
  });
  const client = new Client({
    transport,
    timeoutMs: 10,
    randomHex128: () => "b".repeat(32),
  });
  const opening = client.session(RESOURCE_SESSION).events({ timeoutMs: 10 });
  const socket = FakeWebSocket.instances.at(-1)!;
  socket.open();

  const request = JSON.parse(socket.sent.at(-1)!) as {
    id: string;
    operation: string;
    params: Record<string, unknown>;
  };
  assert.equal(request.operation, "session.events");
  const streamId = request.params.stream_id as string;
  socket.message(JSON.stringify({
    protocol: "cmux.protocol/1",
    type: "response",
    id: request.id,
    ok: true,
    result: { stream_id: streamId },
  }));
  const stream = await opening;
  const next = stream.next({ timeoutMs: 500 });

  await new Promise((resolve) => setTimeout(resolve, 30));
  socket.message(JSON.stringify({
    protocol: "cmux.protocol/1",
    type: "stream_item",
    stream_id: streamId,
    sequence: "0",
    item: { kind: "future", transport: "websocket" },
  }));
  const item = await next;
  assert.equal(item.done, false);
  assert.deepEqual(item.value?.value, {
    kind: "future",
    raw: { kind: "future", transport: "websocket" },
  });

  const canceling = stream.cancel();
  const cancel = JSON.parse(socket.sent.at(-1)!) as {
    id: string;
    operation: string;
  };
  assert.equal(cancel.operation, "stream.cancel");
  socket.message(JSON.stringify({
    protocol: "cmux.protocol/1",
    type: "response",
    id: cancel.id,
    ok: true,
    result: {},
  }));
  socket.message(JSON.stringify({
    protocol: "cmux.protocol/1",
    type: "stream_end",
    stream_id: streamId,
    reason: "canceled",
  }));
  await canceling;
  client.close();
});
