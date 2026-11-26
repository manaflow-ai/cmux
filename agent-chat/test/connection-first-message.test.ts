import assert from "node:assert/strict";
import { openSessionConnection } from "../src/connection";

class Socket {
  onopen: (() => void) | null = null;
  onmessage: ((event: MessageEvent) => void) | null = null;
  onclose: (() => void) | null = null;
  closes = 0;
  // A blackholed connection may never deliver a close callback.
  close() { this.closes++; }
  asWebSocket() { return this as unknown as WebSocket; }
}

const descriptors = new Map(["setTimeout", "clearTimeout"].map((key) => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
const timers = new Map<number, { run: () => void; delay: number }>();
let nextTimer = 1;
Object.defineProperty(globalThis, "setTimeout", { configurable: true, writable: true, value(run: () => void, delay: number) {
  const id = nextTimer++; timers.set(id, { run, delay }); return id;
} });
Object.defineProperty(globalThis, "clearTimeout", { configurable: true, writable: true, value(id: number) { timers.delete(id); } });
function fire() {
  assert.equal(timers.size, 1, "the connection must own exactly one deadline or retry");
  const [id, timer] = [...timers][0];
  timers.delete(id); timer.run();
}
function client() {
  const sockets: Socket[] = [];
  let current: WebSocket | null = null;
  let subscriptions = 0;
  const messages: string[] = [];
  const disconnect = openSessionConnection({
    createSocket() { const socket = new Socket(); sockets.push(socket); return socket.asWebSocket(); },
    onSocket(socket) { current = socket; },
    onOpen() { subscriptions++; },
    onMessage(event) { messages.push(event.data); },
  });
  return { sockets, disconnect, messages, current: () => current, subscriptions: () => subscriptions };
}
const clients: ReturnType<typeof client>[] = [];
const create = () => { const result = client(); clients.push(result); return result; };

try {
  const stalled = create();
  const first = stalled.sockets[0];
  const oldConnectDeadline = [...timers.values()][0].run;
  const lateMessage = first.onmessage!;
  const lateClose = first.onclose!;
  first.onopen?.();
  assert.equal(stalled.subscriptions(), 1);
  assert.equal(timers.size, 1, "an open socket that sends no messages must have a response deadline");
  assert.equal([...timers.values()][0].delay, 15_000);
  oldConnectDeadline();
  assert.equal(first.closes, 0, "a canceled connecting deadline must not expire the response phase");
  const oldResponseDeadline = [...timers.values()][0].run;
  fire();
  assert.equal(first.closes, 1);
  assert.equal(stalled.current(), null);
  assert.equal(first.onmessage, null);
  assert.equal([...timers.values()][0].delay, 800);
  fire();
  assert.equal(stalled.sockets.length, 2);
  const second = stalled.sockets[1];
  second.onopen?.();
  second.onmessage?.({ data: '{"kind":"hello"}' } as MessageEvent);
  lateMessage({ data: "stale history" } as MessageEvent);
  lateClose(); oldResponseDeadline();
  assert.equal(stalled.subscriptions(), 2);
  assert.deepEqual(stalled.messages, ['{"kind":"hello"}']);
  assert.equal(stalled.current(), second.asWebSocket());
  assert.equal(second.closes, 0);
  assert.equal(timers.size, 0, "an idle but responsive chat must not keep a first-message deadline");
  stalled.disconnect();

  const healthy = create();
  healthy.sockets[0].onopen?.();
  const queuedDeadline = [...timers.values()][0].run;
  healthy.sockets[0].onmessage?.({ data: "history" } as MessageEvent);
  queuedDeadline();
  assert.equal(healthy.sockets[0].closes, 0, "a queued response deadline must ignore a socket that already replied");
  assert.equal(timers.size, 0);
  healthy.disconnect();

  const closing = create();
  closing.sockets[0].onopen?.();
  const closedDeadline = [...timers.values()][0].run;
  closing.sockets[0].onclose?.();
  closedDeadline();
  assert.equal(timers.size, 1, "closing during the response phase schedules one retry");
  assert.equal([...timers.values()][0].delay, 800);
  closing.disconnect();

  const unmounted = create();
  unmounted.sockets[0].onopen?.();
  const disposedDeadline = [...timers.values()][0].run;
  unmounted.disconnect(); disposedDeadline();
  assert.equal(unmounted.sockets.length, 1);
  assert.equal(unmounted.sockets[0].closes, 1);
  assert.equal(timers.size, 0);
  console.log("First-message deadlines, resubscription, stale phases, responsive idle sockets, and cleanup: OK");
} finally {
  for (const client of clients) client.disconnect();
  for (const [key, descriptor] of descriptors) {
    if (descriptor) Object.defineProperty(globalThis, key, descriptor);
    else delete (globalThis as any)[key];
  }
}
