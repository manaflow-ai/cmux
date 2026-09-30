import { createContext, useContext } from "react";
import type { SessionState } from "./session";

export const SessionContext = createContext<SessionState | null>(null);

export function useCtx(): SessionState {
  return useContext(SessionContext)!;
}

/// The `owner/name` GitHub repository the current session's working directory
/// belongs to, or `null` when there is none.
///
/// The transcript uses this to resolve bare references such as `#847`. It comes
/// from the working-directory check the session already runs, so no extra round
/// trip is needed, and it is `null` outside a session context so the same
/// components render in the gallery.
export function useRepositorySlug(): string | null {
  const state = useContext(SessionContext);
  const cwd = state?.session?.cwd;
  if (!state || !cwd) return null;
  return state.cwdChecks[cwd]?.repositorySlug ?? null;
}
