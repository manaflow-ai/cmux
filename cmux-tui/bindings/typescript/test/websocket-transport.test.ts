import assert from "node:assert/strict";
import test from "node:test";
import {
  Client,
  CmuxAbortError,
  CmuxConnectionError,
  CmuxTimeoutError,
  MutationTransportUncertainError,
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
import { CmuxClient as RawClient } from "../src/raw/client.js";
import {
  CmuxAbortError as RawCmuxAbortError,
  CmuxTimeoutError as RawCmuxTimeoutError,
} from "../src/raw/errors.js";
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
  sendHook: ((data: string) => void) | undefined;
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
    this.sendHook?.(data);
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
const WEBSOCKET_SURFACES = ["raw", "resource"] as const;

type WebSocketSurface = (typeof WEBSOCKET_SURFACES)[number];

interface SurfaceTransport {
  send(json: string): void;
  close(): void;
  onError(handler: (error: Error) => void): () => void;
  onClose(handler: () => void): () => void;
}

interface SurfaceOptions {
  readonly authToken?: string;
  readonly onPairingChallenge?: (challenge: {
    readonly id?: bigint;
    readonly code: string;
    readonly peer: string;
    readonly expiresIn: number;
  }) => void;
  readonly onPairingCredential?: (credential: string) => void;
  readonly onAuthenticationRejected?: () => void;
}

function createSurfaceTransport(
  surface: WebSocketSurface,
  options: SurfaceOptions = {},
): { readonly transport: SurfaceTransport; readonly socket: FakeWebSocket } {
  if (surface === "raw") {
    const transport = new WebSocketTransport("ws://localhost/cmux", {
      WebSocket: Constructor,
      authToken: options.authToken,
      onPairingChallenge: ({ id, code, peer, expiresIn }) =>
        options.onPairingChallenge?.({ id, code, peer, expiresIn }),
      onPairingCredential: options.onPairingCredential,
      onAuthenticationRejected: options.onAuthenticationRejected,
    });
    return { transport, socket: FakeWebSocket.instances.at(-1)! };
  }
  const transport = new ResourceWebSocketTransport("ws://localhost/cmux", {
    WebSocket: ResourceConstructor,
    authToken: options.authToken,
    onPairingChallenge: ({ code, peer, expiresIn }) =>
      options.onPairingChallenge?.({ code, peer, expiresIn }),
    onPairingCredential: options.onPairingCredential,
    onAuthenticationRejected: options.onAuthenticationRejected,
  });
  return { transport, socket: FakeWebSocket.instances.at(-1)! };
}

function resourceOperationCount(socket: FakeWebSocket, operation: string): number {
  return socket.sent.filter((json) => {
    try {
      return (JSON.parse(json) as { operation?: unknown }).operation === operation;
    } catch {
      return false;
    }
  }).length;
}

function rawMutation(id: number): Record<string, unknown> {
  return {
    id,
    cmd: "rename-workspace",
    workspace: 7,
    name: "never-sent",
  };
}

function abortableRawSend(
  client: RawClient,
  request: Record<string, unknown>,
  signal: AbortSignal,
): Promise<unknown> {
  const sendRaw = client.sendRaw.bind(client) as unknown as (
    request: Record<string, unknown>,
    options: { readonly signal: AbortSignal },
  ) => Promise<unknown>;
  return sendRaw(request, { signal });
}

for (const surface of WEBSOCKET_SURFACES) {
  test(`${surface} WebSocket pairing challenge validation preserves its public shape`, () => {
    const received: Parameters<NonNullable<SurfaceOptions["onPairingChallenge"]>>[0][] = [];
    const errors: Error[] = [];
    const { transport, socket } = createSurfaceTransport(surface, {
      onPairingChallenge: (challenge) => received.push(challenge),
    });
    transport.onError((error) => errors.push(error));

    socket.open();
    socket.message(
      '{"pairing":{"id":7,"code":"123 456","peer":"127.0.0.1","expires_in":60}}',
    );
    socket.message(
      '{"pairing":{"id":"7","code":"bad","peer":"127.0.0.1","expires_in":60}}',
    );

    assert.deepEqual(received, [
      surface === "raw"
        ? { id: 7n, code: "123 456", peer: "127.0.0.1", expiresIn: 60 }
        : { code: "123 456", peer: "127.0.0.1", expiresIn: 60 },
    ]);
    assert.match(errors[0]?.message ?? "", /invalid pairing data/);
    transport.close();
  });

  test(`${surface} WebSocket token mode sends auth before queued frames`, () => {
    const { transport, socket } = createSurfaceTransport(surface, {
      authToken: "shared-token",
    });
    transport.send("queued");

    socket.open();

    assert.deepEqual(socket.sent, [
      '{"auth":{"token":"shared-token"}}',
      "queued",
    ]);
    transport.close();
  });

  for (const preamble of [
    { name: "pairing", authToken: undefined, frame: '"pair"' },
    { name: "authentication", authToken: "shared-token", frame: '"auth"' },
  ] as const) {
    test(`${surface} WebSocket ${preamble.name} preamble failure is terminal`, () => {
      const errors: Error[] = [];
      let closes = 0;
      const { transport, socket } = createSurfaceTransport(surface, {
        authToken: preamble.authToken,
      });
      transport.onError((error) => errors.push(error));
      transport.onClose(() => closes += 1);
      transport.send("queued");
      socket.sendFailure = (data) => data.includes(preamble.frame)
        ? new Error(`${preamble.name} preamble exploded`)
        : undefined;

      assert.doesNotThrow(() => socket.open());
      assert.deepEqual(socket.sent, []);
      assert.match(
        errors[0]?.message ?? "",
        new RegExp(`${preamble.name} preamble failed.*preamble exploded`),
      );
      assert.equal(closes, 1);
      assert.equal(socket.closeCalls, 1);
      assert.throws(() => transport.send("late"), /closed/);
    });
  }

  test(`${surface} WebSocket paired flush failure closes before credential publication`, () => {
    const credentials: string[] = [];
    const errors: Error[] = [];
    let closes = 0;
    const { transport, socket } = createSurfaceTransport(surface, {
      onPairingCredential: (credential) => credentials.push(credential),
    });
    transport.onError((error) => errors.push(error));
    transport.onClose(() => closes += 1);
    transport.send("queued");
    socket.open();
    socket.sendFailure = (data) => data === "queued"
      ? new Error("queued dispatch exploded")
      : undefined;

    assert.doesNotThrow(() => {
      socket.message('{"paired":{"credential":"issued-secret"}}');
    });
    assert.deepEqual(credentials, ["issued-secret"]);
    assert.match(errors[0]?.message ?? "", /dispatch failed.*queued dispatch exploded/);
    assert.equal(closes, 1);
    assert.equal(socket.closeCalls, 1);
    assert.throws(() => transport.send("late"), /closed/);
  });

  test(`${surface} WebSocket credential callback cannot overtake queued frames`, () => {
    let transport!: SurfaceTransport;
    let socket!: FakeWebSocket;
    ({ transport, socket } = createSurfaceTransport(surface, {
      onPairingCredential: () => transport.send("callback"),
    }));
    transport.send("first");
    transport.send("second");

    socket.open();
    socket.message('{"paired":{"credential":"issued-secret"}}');

    assert.deepEqual(socket.sent, [
      '{"pair":{"request":true}}',
      "first",
      "second",
      "callback",
    ]);
    transport.close();
  });

  test(`${surface} WebSocket closing state rejects late frames and duplicate close`, () => {
    const credentials: string[] = [];
    let closes = 0;
    const { transport, socket } = createSurfaceTransport(surface, {
      onPairingCredential: (credential) => credentials.push(credential),
    });
    socket.delayCloseEvent = true;
    transport.onClose(() => closes += 1);
    transport.send("queued");

    transport.close();
    transport.close();
    socket.message('{"paired":{"credential":"late-secret"}}');
    let sendRejected = false;
    try {
      transport.send("late");
    } catch {
      sendRejected = true;
    }
    socket.open();
    socket.finishClose();
    socket.finishClose();

    assert.deepEqual({
      credentials,
      sent: socket.sent,
      sendRejected,
      closeCalls: socket.closeCalls,
      closes,
    }, {
      credentials: [],
      sent: [],
      sendRejected: true,
      closeCalls: 1,
      closes: 1,
    });
  });

  test(`${surface} WebSocket rejection callback throw still fans out close`, () => {
    const calls: string[] = [];
    const { transport, socket } = createSurfaceTransport(surface, {
      authToken: "expired",
      onAuthenticationRejected: () => {
        calls.push("rejected");
        throw new Error("rejection callback failed");
      },
    });
    transport.onError((error) => calls.push(error.constructor.name));
    transport.onClose(() => calls.push("close-one"));
    transport.onClose(() => calls.push("close-two"));
    socket.open();

    assert.throws(
      () => socket.rejectAuthentication(),
      /rejection callback failed/,
    );
    assert.deepEqual(calls, [
      "CmuxAuthenticationRejectedError",
      "rejected",
      "close-one",
      "close-two",
    ]);
  });

  test(`${surface} WebSocket non-text failure fans out and closes`, () => {
    const calls: string[] = [];
    const { transport, socket } = createSurfaceTransport(surface, {
      authToken: "shared-token",
    });
    transport.onError(() => {
      calls.push("error-one");
      throw new Error("first error observer failed");
    });
    transport.onError(() => calls.push("error-two"));
    transport.onClose(() => calls.push("close-one"));
    transport.onClose(() => calls.push("close-two"));
    socket.open();

    assert.throws(
      () => socket.message(Uint8Array.from([1, 2, 3])),
      /first error observer failed/,
    );
    assert.deepEqual(calls, ["error-one", "error-two", "close-one", "close-two"]);
    assert.equal(socket.closeCalls, 1);
    assert.equal(socket.readyState, 3);
  });
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

test("raw WebSocket cancels a mutation that times out before pairing", async () => {
  const transport = new WebSocketTransport("ws://localhost/cmux", {
    WebSocket: Constructor,
  });
  const client = new RawClient({ transport, timeoutMs: 10 });
  const socket = FakeWebSocket.instances.at(-1)!;
  const request = client.sendRaw(rawMutation(101) as never);

  socket.open();
  await assert.rejects(() => request, RawCmuxTimeoutError);
  socket.message('{"paired":{"credential":"resource-secret"}}');

  assert.deepEqual(socket.sent, ['{"pair":{"request":true}}']);
  await client.close();
});

test("raw WebSocket cancels a mutation aborted before pairing", async () => {
  const transport = new WebSocketTransport("ws://localhost/cmux", {
    WebSocket: Constructor,
  });
  const client = new RawClient({ transport, timeoutMs: 1_000 });
  const socket = FakeWebSocket.instances.at(-1)!;
  const controller = new AbortController();
  const request = abortableRawSend(client, rawMutation(102), controller.signal);

  socket.open();
  controller.abort();
  await assert.rejects(() => request, RawCmuxAbortError);
  socket.message('{"paired":{"credential":"resource-secret"}}');

  assert.deepEqual(socket.sent, ['{"pair":{"request":true}}']);
  await client.close();
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

test("resource WebSocket vetoes a mutation whose timer was synchronously starved", async () => {
  const transport = new ResourceWebSocketTransport("ws://localhost/cmux", {
    WebSocket: ResourceConstructor,
  });
  const client = new Client({
    transport,
    randomHex128: () => "f".repeat(32),
  });
  const socket = FakeWebSocket.instances.at(-1)!;
  const renaming = client
    .session(RESOURCE_SESSION)
    .workspace(RESOURCE_WORKSPACE)
    .rename("expired", { timeoutMs: 5 });

  socket.open();
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 20);
  socket.message('{"paired":{"credential":"resource-secret"}}');
  const failure = await renaming.then(
    () => undefined,
    (error: unknown) => error,
  );

  assert.ok(failure instanceof CmuxTimeoutError);
  assert.ok(!(failure instanceof MutationTransportUncertainError));
  assert.deepEqual(socket.sent, ['{"pair":{"request":true}}']);
  client.close();
});

test("resource WebSocket reports synchronous token rejection conclusively", async () => {
  const transport = new ResourceWebSocketTransport("ws://localhost/cmux", {
    WebSocket: ResourceConstructor,
    authToken: "expired",
  });
  const client = new Client({
    transport,
    timeoutMs: 0,
    randomHex128: () => "1".repeat(32),
  });
  const socket = FakeWebSocket.instances.at(-1)!;
  const renaming = client
    .session(RESOURCE_SESSION)
    .workspace(RESOURCE_WORKSPACE)
    .rename("rejected");
  socket.sendHook = (data) => {
    if (data.includes('"auth"')) socket.rejectAuthentication();
  };

  socket.open();
  const failure = await renaming.then(
    () => undefined,
    (error: unknown) => error,
  );

  assert.equal(failure?.constructor.name, "CmuxAuthenticationRejectedError");
  assert.ok(!(failure instanceof MutationTransportUncertainError));
  assert.deepEqual(socket.sent, ['{"auth":{"token":"expired"}}']);
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
