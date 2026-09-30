import { openSessionConnection } from "../src/connection";

class FakeSocket {
  onopen: (() => void) | null = null;
  onmessage: ((event: MessageEvent) => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;
  closed = false;
  closes = 0;
  close() { this.closed = true; this.closes++; this.onclose?.(); }
  asWebSocket() { return this as unknown as WebSocket; }
}

const originalSetTimeout = globalThis.setTimeout;
const originalClearTimeout = globalThis.clearTimeout;
const timers = new Map<number, () => void>();
const delays: number[] = [];
let timerId = 0;
const timerCount = () => timers.size;
globalThis.setTimeout = ((callback: () => void, delay: number) => {
  delays.push(delay);
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

function client(createSocket?: () => WebSocket) {
  const sockets: FakeSocket[] = [];
  let current: WebSocket | null = null;
  let opens = 0;
  const messages: string[] = [];
  const disconnect = openSessionConnection({
    createSocket: createSocket ?? (() => {
      const socket = new FakeSocket();
      sockets.push(socket);
      return socket.asWebSocket();
    }),
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
  if (timerCount() !== 0) throw new Error("disposed chat retained its reconnect timer");

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

  // Browser WebSockets can report an error without delivering close promptly.
  // The view must still arm the same bounded reconnect path instead of
  // remaining forever with a dead socket.
  const errored = client();
  const erroredFirst = errored.sockets[0];
  erroredFirst.onerror?.();
  if (errored.current() !== null || timerCount() !== 1) throw new Error("socket error left the dead connection active or unqueued");
  flushTimers();
  if (errored.sockets.length !== 2) throw new Error("socket error did not create a replacement connection");
  errored.disconnect();

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
  const only = mounted.sockets[0];
  mounted.disconnect();
  // Detached before closing: these handlers capture the whole session closure
  // graph, and the socket outlives cleanup until the close handshake finishes.
  if (only.onopen !== null || only.onmessage !== null || only.onerror !== null || only.onclose !== null) {
    throw new Error("cleanup left handlers attached to the disposed socket");
  }
  mounted.disconnect();
  if (!only.closed || only.closes !== 1) throw new Error("cleanup did not close the socket exactly once");
  if (timerCount() !== 0 || mounted.current() !== null) {
    throw new Error("normal connection cleanup failed or scheduled a retry");
  }

  // A throwing constructor is the one failure that can strand the view: the
  // retry timer is the only thing that calls connect(), so if the throw
  // escapes it there is no socket and no timer left to recover from.
  let attempts = 0;
  const flakySockets: FakeSocket[] = [];
  const flaky = client(() => {
    attempts++;
    if (attempts === 1) throw new Error("SecurityError");
    const socket = new FakeSocket();
    flakySockets.push(socket);
    return socket.asWebSocket();
  });
  if (flaky.current() !== null) throw new Error("a failed connect published a socket");
  if (timerCount() !== 1) throw new Error("a throwing constructor left no retry armed");
  flushTimers();
  if (attempts !== 2 || flakySockets.length !== 1) throw new Error("the retry after a throw did not reconnect");
  if (flaky.current() !== flakySockets[0].asWebSocket()) throw new Error("the recovered socket was not published");
  flaky.disconnect();

  if (delays.length === 0 || delays.some((delay) => delay !== 800)) {
    throw new Error(`reconnect delay changed: ${[...new Set(delays)].join(",")}`);
  }
  console.log("session connection lifecycle assertions passed");
} finally {
  globalThis.setTimeout = originalSetTimeout;
  globalThis.clearTimeout = originalClearTimeout;
}
