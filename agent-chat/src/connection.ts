interface SessionConnection {
  createSocket(): WebSocket;
  onSocket(socket: WebSocket | null): void;
  onOpen(): void;
  onMessage(event: MessageEvent): void;
}

const RETRY_DELAY_MS = 800;

/** Owns the session socket and its reconnect lifecycle for one mounted view. */
export function openSessionConnection(callbacks: SessionConnection): () => void {
  let closed = false;
  let socket: WebSocket | null = null;
  let retry: ReturnType<typeof setTimeout> | null = null;
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
    const scheduleReconnect = () => {
      if (!isCurrent()) return;
      socket = null;
      callbacks.onSocket(null);
      retry = setTimeout(connect, RETRY_DELAY_MS);
    };
    ws.onopen = () => { if (isCurrent()) callbacks.onOpen(); };
    ws.onmessage = (event) => { if (isCurrent()) callbacks.onMessage(event); };
    ws.onerror = () => {
      // Some browser/network failures emit `error` before a delayed (or
      // missing) `close`. Release the dead socket immediately so the view
      // cannot stay permanently disconnected without a retry timer.
      if (!isCurrent()) return;
      ws.onopen = null;
      ws.onmessage = null;
      ws.onerror = null;
      ws.onclose = null;
      scheduleReconnect();
      try { ws.close(); } catch {}
    };
    ws.onclose = () => { scheduleReconnect(); };
  };
  connect();
  return () => {
    closed = true;
    if (retry !== null) clearTimeout(retry);
    retry = null;
    const ws = socket;
    socket = null;
    callbacks.onSocket(null);
    if (ws) {
      // Detach before closing. These handlers capture the whole session
      // closure graph, and the browser keeps the socket alive until the close
      // handshake finishes, which a server that never answers stretches to a
      // TCP timeout. The gates would ignore the callbacks anyway, so the only
      // thing holding them is the unmounted view's state.
      ws.onopen = null;
      ws.onmessage = null;
      ws.onerror = null;
      ws.onclose = null;
      ws.close();
    }
  };
}
