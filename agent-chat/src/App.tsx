import { Tooltip } from "@base-ui-components/react/tooltip";
import { useSession } from "./session";
import { SessionContext } from "./context";
import { Composer } from "./components/Composer";
import { Chat } from "./components/Chat";
import { useOverlayScrollbars } from "./hooks/useOverlayScrollbars";
import { useTypeToFocus } from "./hooks/useTypeToFocus";

export function App() {
  const s = useSession();
  useTypeToFocus();
  useOverlayScrollbars();
  return (
    <Tooltip.Provider delay={500} closeDelay={80} timeout={800}>
      <SessionContext.Provider value={s}>
        <main id="main">
          {!s.ready && s.phase === "composer" ? null : s.phase === "chat" ? <Chat /> : <Composer />}
        </main>
      </SessionContext.Provider>
    </Tooltip.Provider>
  );
}
