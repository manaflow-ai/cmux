import { createContext, useContext } from "react";
import type { SessionState } from "./session";

export const SessionContext = createContext<SessionState | null>(null);

export function useCtx(): SessionState {
  return useContext(SessionContext)!;
}
