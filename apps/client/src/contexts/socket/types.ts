import type {
  AvailableEditors,
  ClientToServerEvents,
  ServerToClientEvents,
} from "@cmux/shared";
import type { Socket } from "socket.io-client";

export interface SocketContextType {
  socket: Socket<ServerToClientEvents, ClientToServerEvents> | null;
  isConnected: boolean;
  availableEditors: AvailableEditors | null;
}

