import { FloatingPane } from "@/components/floating-pane";
import { PersistentWebView } from "@/components/persistent-webview";
import { createFileRoute } from "@tanstack/react-router";
import { useCallback, useMemo, useState, type FormEvent } from "react";

const DEFAULT_URL = "https://example.com/";

function normalizeAddressInput(value: string): string {
  const trimmed = value.trim();
  if (!trimmed) return DEFAULT_URL;

  const hasScheme = /^[a-zA-Z][a-zA-Z0-9+-.]*:/.test(trimmed);
  if (hasScheme) return trimmed;
  if (trimmed.includes(" ")) {
    return `https://duckduckgo.com/?q=${encodeURIComponent(trimmed)}`;
  }
  return `https://${trimmed}`;
}

export const Route = createFileRoute("/_layout/$teamSlugOrId/webview-proxy")({
  component: WebviewProxyRoute,
});

function WebviewProxyRoute() {
  const { teamSlugOrId } = Route.useParams();
  const [addressValue, setAddressValue] = useState(DEFAULT_URL);
  const [currentUrl, setCurrentUrl] = useState(() =>
    normalizeAddressInput(DEFAULT_URL)
  );
  const [reloadSeed, setReloadSeed] = useState(0);

  const persistKey = useMemo(
    () => `webview-proxy:${teamSlugOrId}:${reloadSeed}`,
    [teamSlugOrId, reloadSeed]
  );

  const navigateToAddress = useCallback(
    (value: string) => {
      const normalized = normalizeAddressInput(value);
      setCurrentUrl(normalized);
      setAddressValue(normalized);
      setReloadSeed((seed) => seed + 1);
    },
    []
  );

  const handleSubmit = useCallback(
    (event: FormEvent<HTMLFormElement>) => {
      event.preventDefault();
      navigateToAddress(addressValue);
    },
    [addressValue, navigateToAddress]
  );

  const handleRefresh = useCallback(() => {
    setReloadSeed((seed) => seed + 1);
  }, []);

  return (
    <FloatingPane>
      <div className="flex h-full flex-col gap-4 p-4 text-neutral-900 dark:text-neutral-100">
        <div className="space-y-1">
          <h1 className="text-2xl font-semibold">Webview Proxy</h1>
          <p className="text-sm text-neutral-600 dark:text-neutral-400">
            Prototype surface for streaming a proxied workspace into the app.
          </p>
        </div>

        <form
          onSubmit={handleSubmit}
          className="flex flex-wrap items-center gap-2"
        >
          <input
            type="text"
            value={addressValue}
            onChange={(event) => setAddressValue(event.target.value)}
            className="min-w-0 flex-1 rounded-md border border-neutral-300 bg-white px-3 py-2 text-sm text-neutral-900 shadow-sm focus:border-neutral-500 focus:outline-none dark:border-neutral-700 dark:bg-neutral-900 dark:text-neutral-50"
            placeholder="https://workspace.example.dev/"
            spellCheck={false}
          />
          <div className="flex items-center gap-1">
            <button
              type="submit"
              className="rounded-md border border-neutral-300 bg-neutral-50 px-3 py-2 text-sm font-medium text-neutral-800 transition hover:bg-neutral-100 focus-visible:outline focus-visible:outline-offset-2 focus-visible:outline-neutral-500 dark:border-neutral-700 dark:bg-neutral-800 dark:text-neutral-100 dark:hover:bg-neutral-700 dark:focus-visible:outline-neutral-400"
            >
              Go
            </button>
            <button
              type="button"
              onClick={handleRefresh}
              className="rounded-md border border-neutral-300 bg-neutral-50 px-3 py-2 text-sm font-medium text-neutral-800 transition hover:bg-neutral-100 focus-visible:outline focus-visible:outline-offset-2 focus-visible:outline-neutral-500 dark:border-neutral-700 dark:bg-neutral-800 dark:text-neutral-100 dark:hover:bg-neutral-700 dark:focus-visible:outline-neutral-400"
            >
              Reload
            </button>
          </div>
        </form>

        <div className="flex flex-1 flex-col gap-3">
          <div className="flex flex-wrap gap-2 text-sm text-neutral-600 dark:text-neutral-400">
            {["https://example.com/", "https://news.ycombinator.com/"].map(
              (preset) => (
                <button
                  key={preset}
                  type="button"
                  onClick={() => navigateToAddress(preset)}
                  className="rounded-full border border-neutral-200 px-3 py-1 text-xs font-medium text-neutral-700 transition hover:border-neutral-400 hover:text-neutral-900 dark:border-neutral-700 dark:text-neutral-200 dark:hover:border-neutral-500 dark:hover:text-neutral-50"
                >
                  {preset.replace(/^https?:\/\//, "")}
                </button>
              )
            )}
          </div>

          <div className="flex flex-1 flex-col gap-2">
            <div className="text-sm text-neutral-600 dark:text-neutral-400">
              The view automatically upgrades to Electron&apos;s WebContentsView
              when running in the desktop app and falls back to a regular iframe
              in the browser.
            </div>

            <div className="flex flex-1 flex-col overflow-hidden rounded-lg border border-neutral-200 bg-neutral-50 dark:border-neutral-800 dark:bg-neutral-950">
              <PersistentWebView
                persistKey={persistKey}
                src={currentUrl}
                className="h-full w-full flex-1 bg-white dark:bg-neutral-900"
                iframeClassName="h-full w-full"
                forceWebContentsViewIfElectron
              />
            </div>
          </div>
        </div>
      </div>
    </FloatingPane>
  );
}
