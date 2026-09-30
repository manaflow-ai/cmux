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
  const connect = () => {
    const ws = callbacks.createSocket();
    socket = ws;
    callbacks.onSocket(ws);
    ws.onopen = callbacks.onOpen;
    ws.onmessage = callbacks.onMessage;
    ws.onclose = () => { if (!closed) setTimeout(connect, 800); };
  };
  connect();
  return () => {
    closed = true;
    socket?.close();
  };
}
