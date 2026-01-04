import type { AvailableEditors } from "@cmux/shared";
import type { MainServerSocket } from "@cmux/shared/socket";

// Re-export MainServerSocket as CmuxSocket for backward compatibility
export type CmuxSocket = MainServerSocket;
export interface SocketContextType {
  socket: CmuxSocket | null;
  isConnected: boolean;
  availableEditors: AvailableEditors | null;
}
