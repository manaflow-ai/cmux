import { useEffect, useRef } from "react";
import { Tooltip } from "@base-ui-components/react/tooltip";
import { useSession, type SessionState } from "./session";
import { RepositorySlugContext, SessionContext } from "./context";
import { Composer } from "./components/Composer";
import { Chat } from "./components/Chat";
import { useOverlayScrollbars } from "./hooks/useOverlayScrollbars";
import { useTypeToFocus } from "./hooks/useTypeToFocus";

export function App() {
  const s = useSession();
  // A string, not a slice of the session state, so the transcript's memoized
  // messages only re-render when the repository actually changes.
  const repositorySlug = s.session?.cwd ? s.cwdChecks[s.session.cwd]?.repositorySlug ?? null : null;
  useSessionCwdCheck(s);
  useTypeToFocus();
  useOverlayScrollbars();
  return (
    <Tooltip.Provider delay={500} closeDelay={80} timeout={800}>
      <SessionContext.Provider value={s}>
        <RepositorySlugContext.Provider value={repositorySlug}>
          <main id="main">
            {s.phase === "chat" ? <Chat /> : <Composer />}
          </main>
        </RepositorySlugContext.Provider>
      </SessionContext.Provider>
    </Tooltip.Provider>
  );
}

/// Asks the server about the session's working directory once, so the
/// transcript knows which repository a bare `#847` belongs to.
///
/// The composer runs this check for a directory someone types; a session
/// started elsewhere, or restored on a reconnect, never passed through it. The
/// requested directories are held in a ref rather than read back out of
/// `cwdChecks`, because that map's identity changes on every check the composer
/// makes and the session's own answer takes a round trip to arrive.
function useSessionCwdCheck(state: SessionState) {
  const { ready, phase, session, checkCwd } = state;
  const requested = useRef(new Set<string>());
  const cwd = session?.cwd;
  useEffect(() => {
    if (!ready || phase !== "chat" || !cwd || requested.current.has(cwd)) return;
    requested.current.add(cwd);
    checkCwd(cwd);
  }, [checkCwd, cwd, phase, ready]);
}
