import assert from "node:assert/strict";
import { openSessionConnection } from "../src/connection";

function signal() {
  let resolve!: () => void;
  const promise = new Promise<void>((done) => { resolve = done; });
  return { promise, resolve };
}
const originalSetTimeout = globalThis.setTimeout;
const originalClearTimeout = globalThis.clearTimeout;
async function bounded(promise: Promise<void>) {
  let guard: ReturnType<typeof setTimeout>;
  const timeout = new Promise<void>((_, reject) => {
    guard = originalSetTimeout(() => reject(new Error("local WebSocket fixture did not finish")), 2_000);
  });
  try { await Promise.race([promise, timeout]); }
  finally { originalClearTimeout(guard!); }
}

const firstSubscribed = signal();
const historyReceived = signal();
const requests: { connection: number; op: string; sessionId: string }[] = [];
let connections = 0;
const server = Bun.serve<{ id: number }>({
  hostname: "127.0.0.1", port: 0,
  fetch(request, server) {
    if (server.upgrade(request, { data: { id: ++connections } })) return;
    return new Response("upgrade required", { status: 426 });
  },
  websocket: {
    message(socket, raw) {
      const request = JSON.parse(String(raw));
      requests.push({ connection: socket.data.id, op: request.op, sessionId: request.sessionId });
      if (socket.data.id === 1) {
        // Successfully upgraded, but the application never sends a greeting.
        firstSubscribed.resolve();
      } else {
        socket.send(JSON.stringify({ kind: "hello" }));
        socket.send(JSON.stringify({ kind: "history", session: { id: request.sessionId }, events: [{ kind: "user", text: "recovered" }] }));
      }
    },
  },
});

const descriptors = new Map(["setTimeout", "clearTimeout"].map((key) => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
const timers = new Map<number, { run: () => void; delay: number }>();
let nextTimer = 1;
Object.defineProperty(globalThis, "setTimeout", { configurable: true, writable: true, value(run: () => void, delay: number) {
  const id = nextTimer++; timers.set(id, { run, delay }); return id;
} });
Object.defineProperty(globalThis, "clearTimeout", { configurable: true, writable: true, value(id: number) { timers.delete(id); } });
function fire(delay: number) {
  assert.equal(timers.size, 1, "one connection deadline or retry is pending");
  const [id, timer] = [...timers][0];
  assert.equal(timer.delay, delay);
  timers.delete(id); timer.run();
}

let socket: WebSocket | null = null;
const received: any[] = [];
let disconnect: (() => void) | undefined;
try {
  disconnect = openSessionConnection({
    createSocket: () => new WebSocket(`ws://127.0.0.1:${server.port}`),
    onSocket: (next) => { socket = next; },
    onOpen: () => { socket!.send(JSON.stringify({ op: "subscribe", sessionId: "existing-session" })); },
    onMessage: (event) => {
      const message = JSON.parse(event.data); received.push(message);
      if (message.kind === "history") historyReceived.resolve();
    },
  });
  await bounded(firstSubscribed.promise);
  assert.equal(received.length, 0);
  fire(15_000);
  assert.equal(socket, null, "a silent upgraded socket must be retired without waiting for close");
  fire(800);
  await bounded(historyReceived.promise);
  assert.deepEqual(requests, [
    { connection: 1, op: "subscribe", sessionId: "existing-session" },
    { connection: 2, op: "subscribe", sessionId: "existing-session" },
  ]);
  assert.deepEqual(received, [
    { kind: "hello" },
    { kind: "history", session: { id: "existing-session" }, events: [{ kind: "user", text: "recovered" }] },
  ]);
  assert.equal(timers.size, 0, "a responsive idle socket has no response deadline");
  disconnect();
  assert.equal(socket, null);
  assert.equal(timers.size, 0);
  console.log("Real WebSocket upgrade stall reconnects, resubscribes, and recovers history: OK");
} finally {
  disconnect?.();
  for (const [key, descriptor] of descriptors) {
    if (descriptor) Object.defineProperty(globalThis, key, descriptor);
    else delete (globalThis as any)[key];
  }
  await server.stop(true);
}
