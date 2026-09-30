interface SessionConnection {
  createSocket(): WebSocket;
  onSocket(socket: WebSocket | null): void;
  onOpen(): void;
  onMessage(event: MessageEvent): void;
}

/** Owns the session socket and its reconnect lifecycle for one mounted view. */
export function openSessionConnection(callbacks: SessionConnection): () => void {
  let closed = false;
  let socket: WebSocket | null = null;
  let retry: ReturnType<typeof setTimeout> | null = null;
  const connect = () => {
    if (closed) return;
    retry = null;
    const ws = callbacks.createSocket();
    socket = ws;
    callbacks.onSocket(ws);
    const isCurrent = () => !closed && socket === ws;
    ws.onopen = () => { if (isCurrent()) callbacks.onOpen(); };
    ws.onmessage = (event) => { if (isCurrent()) callbacks.onMessage(event); };
    ws.onclose = () => {
      if (!isCurrent()) return;
      socket = null;
      callbacks.onSocket(null);
      retry = setTimeout(connect, 800);
    };
  };
  connect();
  return () => {
    closed = true;
    if (retry !== null) clearTimeout(retry);
    retry = null;
    const ws = socket;
    socket = null;
    callbacks.onSocket(null);
    ws?.close();
  };
}
