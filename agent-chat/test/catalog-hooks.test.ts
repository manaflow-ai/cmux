import assert from "node:assert/strict";
import { createElement } from "react";
import { act, create, type ReactTestRenderer } from "react-test-renderer";
import { useProviderCatalogs } from "../src/hooks/useCatalogs";
import type { Provider } from "../src/session";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const providers: Provider[] = [
  { id: "claude", label: "Claude", installed: true },
  { id: "codex", label: "Codex", installed: true },
];

function CatalogProbe({ requestCommands }: { requestCommands?: (provider: string, cwd: string) => void }) {
  useProviderCatalogs(
    true,
    1,
    providers,
    "claude",
    "/repo",
    () => {},
    requestCommands,
  );
  return createElement("div");
}

let renderer: ReactTestRenderer | undefined;
try {
  let commandRequests = 0;
  act(() => {
    // Keep this call source-compatible with the pre-fix hook so the regression
    // fails before the optional composer-only callback is implemented.
    renderer = create(createElement(CatalogProbe, { requestCommands: undefined as unknown as (provider: string, cwd: string) => void }));
  });
  assert.equal(commandRequests, 0, "chat's provider catalog must not fetch unused commands");

  act(() => {
    renderer!.update(createElement(CatalogProbe, {
      requestCommands: () => { commandRequests += 1; },
    }));
  });
  assert.equal(commandRequests, 1, "the composer may opt into command discovery");
  console.log("provider catalog hooks: chat skips command fetch, composer opts in: OK");
} finally {
  if (renderer) act(() => renderer!.unmount());
}
