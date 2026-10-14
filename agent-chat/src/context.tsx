import { createContext, useContext } from "react";
import type { SessionState } from "./session";

export const SessionContext = createContext<SessionState | null>(null);

export function useCtx(): SessionState {
  return useContext(SessionContext)!;
}

/// The `owner/name` GitHub repository the current session's working directory
/// belongs to, or `null` when there is none.
///
/// This is its own context rather than a field read off `SessionContext`
/// because every transcript message consumes it. A context consumer re-renders
/// whenever the context value changes, and the session state is a fresh object
/// on every render, so reading the slug through it would re-render and re-parse
/// every message in the transcript on every streamed token. A string changes
/// about once per session, so `memo` keeps holding.
export const RepositorySlugContext = createContext<string | null>(null);

export function useRepositorySlug(): string | null {
  return useContext(RepositorySlugContext);
}
