interface SessionConnection {
  createSocket(): WebSocket;
  onSocket(socket: WebSocket | null): void;
  onOpen(): void;
  onMessage(event: MessageEvent): void;
}

const RETRY_DELAY_MS = 800;
const CONNECT_TIMEOUT_MS = 15_000;

function detachSocket(ws: WebSocket): void {
  ws.onopen = null;
  ws.onmessage = null;
  ws.onclose = null;
}

/** Owns the session socket and its reconnect lifecycle for one mounted view. */
export function openSessionConnection(callbacks: SessionConnection): () => void {
  let closed = false;
  let socket: WebSocket | null = null;
  let retry: ReturnType<typeof setTimeout> | null = null;
  let opening: ReturnType<typeof setTimeout> | null = null;
  const clearOpeningTimeout = () => {
    if (opening !== null) clearTimeout(opening);
    opening = null;
  };
  const connect = () => {
    if (closed) return;
    retry = null;
    let ws: WebSocket;
    try {
      ws = callbacks.createSocket();
    } catch {
      // The constructor throws on a bad URL or an opaque origin, and this call
      // is the only thing that ever re-arms a retry. Letting it escape the
      // timer leaves no socket and no pending timer, so the view would sit at
      // ready with every send returning false and nothing to recover it.
      retry = setTimeout(connect, RETRY_DELAY_MS);
      return;
    }
    socket = ws;
    callbacks.onSocket(ws);
    const isCurrent = () => !closed && socket === ws;
    ws.onopen = () => {
      if (!isCurrent()) return;
      clearOpeningTimeout();
      callbacks.onOpen();
    };
    ws.onmessage = (event) => { if (isCurrent()) callbacks.onMessage(event); };
    ws.onclose = () => {
      if (!isCurrent()) return;
      clearOpeningTimeout();
      socket = null;
      callbacks.onSocket(null);
      retry = setTimeout(connect, RETRY_DELAY_MS);
    };
    opening = setTimeout(() => {
      // A cancelled deadline may already be queued. Never retire a socket
      // that has opened, been replaced, or belongs to an unmounted view.
      if (!isCurrent() || opening === null) return;
      clearOpeningTimeout();
      socket = null;
      detachSocket(ws);
      callbacks.onSocket(null);
      // Re-arm before closing; recovery must not depend on a close event.
      retry = setTimeout(connect, RETRY_DELAY_MS);
      ws.close();
    }, CONNECT_TIMEOUT_MS);
  };
  connect();
  return () => {
    closed = true;
    if (retry !== null) clearTimeout(retry);
    retry = null;
    clearOpeningTimeout();
    const ws = socket;
    socket = null;
    callbacks.onSocket(null);
    if (ws) {
      // Detach before closing. These handlers capture the whole session
      // closure graph, and the browser keeps the socket alive until the close
      // handshake finishes, which a server that never answers stretches to a
      // TCP timeout. The gates would ignore the callbacks anyway, so the only
      // thing holding them is the unmounted view's state.
      detachSocket(ws);
      ws.close();
    }
  };
}
