interface SessionConnection {
  createSocket(): WebSocket;
  onSocket(socket: WebSocket | null): void;
  onOpen(): void;
  onMessage(event: MessageEvent): void;
}

const RETRY_DELAY_MS = 800;
const RESPONSE_TIMEOUT_MS = 15_000;

function detachSocket(ws: WebSocket): void {
  ws.onopen = null;
  ws.onmessage = null;
  ws.onerror = null;
  ws.onclose = null;
}

/** Owns the session socket and its reconnect lifecycle for one mounted view. */
export function openSessionConnection(callbacks: SessionConnection): () => void {
  let closed = false;
  let socket: WebSocket | null = null;
  let retry: ReturnType<typeof setTimeout> | null = null;
  let deadline: ReturnType<typeof setTimeout> | null = null;
  const clearDeadline = () => {
    if (deadline !== null) clearTimeout(deadline);
    deadline = null;
  };
  const connect = () => {
    if (closed) return;
    retry = null;
    let ws: WebSocket;
    try {
      ws = callbacks.createSocket();
    } catch {
      retry = setTimeout(connect, RETRY_DELAY_MS);
      return;
    }
    socket = ws;
    callbacks.onSocket(ws);
    const isCurrent = () => !closed && socket === ws;
    const scheduleReconnect = () => {
      if (!isCurrent()) return;
      clearDeadline();
      socket = null;
      callbacks.onSocket(null);
      retry = setTimeout(connect, RETRY_DELAY_MS);
    };
    const armDeadline = () => {
      clearDeadline();
      const timer = setTimeout(() => {
        if (!isCurrent() || deadline !== timer) return;
        clearDeadline();
        socket = null;
        detachSocket(ws);
        callbacks.onSocket(null);
        retry = setTimeout(connect, RETRY_DELAY_MS);
        ws.close();
      }, RESPONSE_TIMEOUT_MS);
      deadline = timer;
    };
    ws.onopen = () => {
      if (!isCurrent()) return;
      armDeadline();
      callbacks.onOpen();
    };
    ws.onmessage = (event) => {
      if (!isCurrent()) return;
      clearDeadline();
      callbacks.onMessage(event);
    };
    ws.onerror = () => {
      if (!isCurrent()) return;
      detachSocket(ws);
      scheduleReconnect();
      try { ws.close(); } catch {}
    };
    ws.onclose = () => { scheduleReconnect(); };
    armDeadline();
  };
  connect();
  return () => {
    closed = true;
    if (retry !== null) clearTimeout(retry);
    retry = null;
    clearDeadline();
    const ws = socket;
    socket = null;
    callbacks.onSocket(null);
    if (ws) {
      detachSocket(ws);
      ws.close();
    }
  };
}
