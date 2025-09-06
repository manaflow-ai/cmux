import { createContext } from "react";
import type { SocketContextType } from "./types";

export const WebSocketContext = createContext<SocketContextType | null>(null);
export const ElectronSocketContext = createContext<SocketContextType | null>(
  null
);
