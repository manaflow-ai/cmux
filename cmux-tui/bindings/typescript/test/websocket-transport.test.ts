import assert from "node:assert/strict";
import test from "node:test";
import {
  WebSocketTransport,
  type WebSocketConstructor,
  type WebSocketLike,
} from "../src/websocket-transport.js";

class FakeWebSocket implements WebSocketLike {
  static readonly instances: FakeWebSocket[] = [];
  readonly sent: string[] = [];
  readonly url: string;
  readonly protocols?: string | string[];
  readyState = 0;
  private readonly listeners = new Map<string, Set<(event: unknown) => void>>();

  constructor(url: string | URL, protocols?: string | string[]) {
    this.url = String(url);
    this.protocols = protocols;
    FakeWebSocket.instances.push(this);
  }

  send(data: string): void { this.sent.push(data); }
  close(): void { this.readyState = 3; this.emit("close", {}); }
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

test("WebSocketTransport pairs before flushing queued protocol frames", () => {
  const challenges: string[] = [];
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
    onPairingChallenge: (challenge) => challenges.push(challenge.code),
    onPairingCredential: (credential) => credentials.push(credential),
  });
  const approvedSocket = FakeWebSocket.instances.at(-1)!;
  approved.send('{"id":1,"cmd":"ping"}');
  approvedSocket.open();
  approvedSocket.message('{"pairing":{"id":7,"code":"123 456","peer":"127.0.0.1","expires_in":60}}');
  assert.deepEqual(challenges, ["123 456"]);
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
