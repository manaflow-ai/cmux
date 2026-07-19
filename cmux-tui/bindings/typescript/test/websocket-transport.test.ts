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

test("WebSocketTransport queues until open and sends one JSON text frame", () => {
  const transport = new WebSocketTransport("ws://localhost/cmux", { WebSocket: Constructor, protocols: "cmux" });
  const socket = FakeWebSocket.instances.at(-1)!;
  transport.send('{"id":1,"cmd":"ping"}');
  assert.deepEqual(socket.sent, []);
  socket.open();
  assert.deepEqual(socket.sent, ['{"id":1,"cmd":"ping"}']);
  assert.equal(socket.url, "ws://localhost/cmux");
  assert.equal(socket.protocols, "cmux");
  transport.close();
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

test("WebSocketTransport forwards text, errors, and close", () => {
  const transport = new WebSocketTransport("ws://localhost/cmux", Constructor);
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
  const transport = new WebSocketTransport("ws://localhost/cmux", Constructor);
  const socket = FakeWebSocket.instances.at(-1)!;
  const errors: Error[] = [];
  transport.onError((error) => errors.push(error));
  socket.open();
  socket.message(Uint8Array.from([1, 2, 3]));
  assert.match(errors[0]?.message ?? "", /non-text frame/);
  transport.close();
});
