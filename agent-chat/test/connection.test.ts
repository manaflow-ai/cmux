import { openSessionConnection } from "../src/connection";

class FakeSocket {
  onopen: (() => void) | null = null;
  onmessage: ((event: MessageEvent) => void) | null = null;
  onclose: (() => void) | null = null;
  closed = false;
  close() { this.closed = true; this.onclose?.(); }
  asWebSocket() { return this as unknown as WebSocket; }
}

const originalSetTimeout = globalThis.setTimeout;
const originalClearTimeout = globalThis.clearTimeout;
const timers = new Map<number, () => void>();
let timerId = 0;
const timerCount = () => timers.size;
globalThis.setTimeout = ((callback: () => void, delay: number) => {
  if (delay !== 800) throw new Error(`unexpected reconnect delay: ${delay}`);
  const id = ++timerId;
  timers.set(id, callback);
  return id;
}) as unknown as typeof setTimeout;
globalThis.clearTimeout = ((id: number) => { timers.delete(id); }) as typeof clearTimeout;

function flushTimers() {
  const pending = [...timers.values()];
  timers.clear();
  for (const callback of pending) callback();
}

function client() {
  const sockets: FakeSocket[] = [];
  let current: WebSocket | null = null;
  let opens = 0;
  const messages: string[] = [];
  const disconnect = openSessionConnection({
    createSocket: () => {
      const socket = new FakeSocket();
      sockets.push(socket);
      return socket.asWebSocket();
    },
    onSocket: (socket) => { current = socket; },
    onOpen: () => { opens++; },
    onMessage: (event) => { messages.push(event.data); },
  });
  return { sockets, messages, disconnect, current: () => current, opens: () => opens };
}

try {
  const disposed = client();
  disposed.sockets[0].close();
  disposed.disconnect();
  const leakedTimers = timerCount();
  // Drain even a leaked retry to demonstrate that it must not open a socket.
  flushTimers();
  if (disposed.sockets.length !== 1) {
    throw new Error("disposed chat reopened a WebSocket from a pending reconnect");
  }
  if (leakedTimers !== 0) throw new Error("disposed chat retained its reconnect timer");
  if (disposed.current() !== null) throw new Error("disposed chat retained a sendable socket reference");

  const recovering = client();
  const first = recovering.sockets[0];
  const staleOpen = first.onopen!;
  const staleMessage = first.onmessage!;
  const staleClose = first.onclose!;
  first.onopen?.();
  first.onmessage?.({ data: "first history" } as MessageEvent);
  first.close();
  staleClose();
  if (recovering.current() !== null) throw new Error("closed connection still owns the send socket");
  if (timerCount() !== 1) throw new Error("one closed socket scheduled multiple reconnects");
  flushTimers();
  if (recovering.sockets.length !== 2) throw new Error("connection failed to open exactly one replacement socket");
  const second = recovering.sockets[1];
  second.onopen?.();
  second.onmessage?.({ data: "replacement history" } as MessageEvent);
  staleOpen();
  staleMessage({ data: "stale history" } as MessageEvent);
  staleClose();
  if (recovering.opens() !== 2) throw new Error("stale socket resubscribed the current chat");
  if (recovering.messages.join(",") !== "first history,replacement history") {
    throw new Error("stale socket replaced the recovered chat's history");
  }
  if (timerCount() !== 0) throw new Error("stale socket scheduled another connection");
  if (recovering.current() !== second.asWebSocket()) throw new Error("stale socket cleared the replacement connection");

  // The retry may already be queued for execution when the view is disposed.
  second.close();
  const queuedRetry = [...timers.values()][0];
  recovering.disconnect();
  queuedRetry();
  staleOpen();
  staleMessage({ data: "late history" } as MessageEvent);
  if (recovering.sockets.length !== 2 || recovering.opens() !== 2 || recovering.messages.length !== 2) {
    throw new Error("disposed connection accepted a queued retry or stale callback");
  }
  if (timerCount() !== 0 || recovering.current() !== null) throw new Error("connection cleanup left owned state behind");

  const mounted = client();
  mounted.disconnect();
  mounted.disconnect();
  if (!mounted.sockets[0].closed || timerCount() !== 0 || mounted.current() !== null) {
    throw new Error("normal connection cleanup failed or scheduled a retry");
  }
  console.log("session connection lifecycle assertions passed");
} finally {
  globalThis.setTimeout = originalSetTimeout;
  globalThis.clearTimeout = originalClearTimeout;
}
