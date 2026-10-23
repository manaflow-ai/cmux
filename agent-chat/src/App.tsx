import { Tooltip } from "@base-ui-components/react/tooltip";
import { useSession } from "./session";
import { useSessionCwdCheck } from "./hooks/useCatalogs";
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
            {!s.ready && s.phase === "composer" ? null : s.phase === "chat" ? <Chat /> : <Composer />}
          </main>
        </RepositorySlugContext.Provider>
      </SessionContext.Provider>
    </Tooltip.Provider>
  );
}
