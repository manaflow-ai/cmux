import assert from "node:assert/strict";
import test from "node:test";
import {
  type WebSocketConstructor,
  type WebSocketLike,
} from "cmux-sdk/browser";
import { createWebSocketBrowserController } from "../src/index.js";

class ServerWebSocket implements WebSocketLike {
  static readonly instances: ServerWebSocket[] = [];
  readonly sent: string[] = [];
  readonly url: string;
  readonly protocols: string | string[] | undefined;
  readyState = 0;
  private readonly listeners = new Map<string, Set<(event: unknown) => void>>();

  constructor(url: string | URL, protocols?: string | string[]) {
    this.url = String(url);
    this.protocols = protocols;
    ServerWebSocket.instances.push(this);
  }

  addEventListener(type: string, listener: (event: never) => void): void {
    const listeners = this.listeners.get(type) ?? new Set();
    listeners.add(listener as (event: unknown) => void);
    this.listeners.set(type, listeners);
  }

  send(data: string): void {
    this.sent.push(data);
    const value = JSON.parse(data) as Record<string, unknown>;
    if ("auth" in value) return;
    if (value.operation === "browser.list") {
      this.message({
        protocol: "cmux.protocol/2",
        type: "response",
        id: value.id,
        ok: true,
        result: [],
      });
    }
  }

  close(): void {
    if (this.readyState === 3) return;
    this.readyState = 3;
    this.emit("close", {});
  }

  open(): void {
    this.readyState = 1;
    this.emit("open", {});
  }

  private message(value: unknown): void {
    this.emit("message", { data: JSON.stringify(value) });
  }

  private emit(type: string, event: unknown): void {
    for (const listener of this.listeners.get(type) ?? []) listener(event);
  }
}

test("uses the injected WebSocket through the public resource client", async () => {
  ServerWebSocket.instances.length = 0;
  const controller = createWebSocketBrowserController({
    url: "ws://127.0.0.1:7681",
    WebSocket: ServerWebSocket as unknown as WebSocketConstructor,
    protocols: "cmux-resource-v2",
    authToken: "test-token",
    controller: { recoveryDelayMs: 0 },
  });

  const listing = controller.listBrowserTabs();
  await Promise.resolve();
  const socket = ServerWebSocket.instances[0];
  assert.ok(socket);
  socket.open();
  assert.deepEqual(await listing, []);
  assert.equal(socket.url, "ws://127.0.0.1:7681");
  assert.equal(socket.protocols, "cmux-resource-v2");
  assert.equal(socket.sent[0], '{"auth":{"token":"test-token"}}');
  assert.match(socket.sent[1] ?? "", /"operation":"browser.list"/);
  assert.doesNotMatch(socket.sent[1] ?? "", /"cmd":/);
  await controller.close();
});
