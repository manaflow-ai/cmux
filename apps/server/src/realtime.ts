import type { ClientToServerEvents, ServerToClientEvents } from "@cmux/shared";

export interface RealtimeSocket {
  id: string;
  handshake: {
    query: Record<string, string | string[] | undefined>;
  };
  on<E extends keyof ClientToServerEvents>(
    event: E,
    handler: ClientToServerEvents[E]
  ): void;
  emit<E extends keyof ServerToClientEvents>(
    event: E,
    ...args: Parameters<ServerToClientEvents[E]>
  ): void;
  use(middleware: (packet: unknown[], next: () => void) => void): void;
  disconnect(): void;
}

export interface RealtimeServer {
  onConnection(handler: (socket: RealtimeSocket) => void): void;
  emit<E extends keyof ServerToClientEvents>(
    event: E,
    ...args: Parameters<ServerToClientEvents[E]>
  ): void;
  close(): Promise<void>;
}

export type CreateRealtimeServer = () => RealtimeServer;
