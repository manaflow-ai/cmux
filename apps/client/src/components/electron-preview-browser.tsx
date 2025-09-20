import {
  ArrowLeft,
  ArrowRight,
  Inspect,
  Loader2,
  RefreshCw,
} from "lucide-react";
import type { CSSProperties } from "react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import { PersistentWebView } from "@/components/persistent-webview";
import { Button } from "@/components/ui/button";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import { cn } from "@/lib/utils";
import type {
  ElectronDevToolsMode,
  ElectronWebContentsEvent,
  ElectronWebContentsState,
} from "@/types/electron-webcontents";
import clsx from "clsx";

interface ElectronPreviewBrowserProps {
  persistKey: string;
  src: string;
  borderRadius?: number;
}

interface NativeViewHandle {
  id: number;
  webContentsId: number;
  restored: boolean;
}

function normalizeUrl(raw: string): string {
  const trimmed = raw.trim();
  if (trimmed.length === 0) return trimmed;
  if (/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(trimmed)) {
    return trimmed;
  }
  if (trimmed.startsWith("//")) {
    return `https:${trimmed}`;
  }
  return `https://${trimmed}`;
}

function useLoadingProgress(isLoading: boolean) {
  const [progress, setProgress] = useState(0);
  const [visible, setVisible] = useState(false);

  useEffect(() => {
    let interval: ReturnType<typeof setInterval> | null = null;
    let timeout: ReturnType<typeof setTimeout> | null = null;

    if (isLoading) {
      setVisible(true);
      setProgress((prev) => (prev <= 0 ? 0.08 : prev));
      interval = setInterval(() => {
        setProgress((prev) => {
          const next = prev + (1 - prev) * 0.18;
          return Math.min(next, 0.95);
        });
      }, 120);
    } else {
      setProgress((prev) => (prev === 0 ? 0 : 1));
      timeout = setTimeout(() => {
        setVisible(false);
        setProgress(0);
      }, 260);
    }

    return () => {
      if (interval) clearInterval(interval);
      if (timeout) clearTimeout(timeout);
    };
  }, [isLoading]);

  return { progress, visible };
}

export function ElectronPreviewBrowser({
  persistKey,
  src,
}: ElectronPreviewBrowserProps) {
  const [viewHandle, setViewHandle] = useState<NativeViewHandle | null>(null);
  const [addressValue, setAddressValue] = useState(src);
  const [committedUrl, setCommittedUrl] = useState(src);
  const [isEditing, setIsEditing] = useState(false);
  const [isLoading, setIsLoading] = useState(false);
  const [devtoolsOpen, setDevtoolsOpen] = useState(false);
  const [devtoolsMode] = useState<ElectronDevToolsMode>("right");
  const [lastError, setLastError] = useState<string | null>(null);
  const [canGoBack, setCanGoBack] = useState(false);
  const [canGoForward, setCanGoForward] = useState(false);
  const inputRef = useRef<HTMLInputElement | null>(null);

  const { progress, visible } = useLoadingProgress(isLoading);

  useEffect(() => {
    setAddressValue(src);
    setCommittedUrl(src);
    setLastError(null);
    setCanGoBack(false);
    setCanGoForward(false);
  }, [src]);

  const applyState = useCallback(
    (state: ElectronWebContentsState) => {
      setCommittedUrl(state.url);
      if (!isEditing) {
        setAddressValue(state.url);
      }
      setIsLoading(state.isLoading);
      setDevtoolsOpen(state.isDevToolsOpened);
      setCanGoBack(Boolean(state.canGoBack));
      setCanGoForward(Boolean(state.canGoForward));
      if (state.isLoading) {
        setLastError(null);
      }
    },
    [isEditing]
  );

  useEffect(() => {
    if (!viewHandle) return;
    const getState = window.cmux.webContentsView.getState;
    if (!getState) return;
    let disposed = false;
    void getState(viewHandle.id)
      .then((result) => {
        if (disposed) return;
        if (result?.ok && result.state) {
          applyState(result.state);
        }
      })
      .catch((error: unknown) => {
        console.warn("Failed to get WebContentsView state", error);
      });
    return () => {
      disposed = true;
    };
  }, [applyState, viewHandle]);

  useEffect(() => {
    if (!viewHandle) return;
    const subscribe = window.cmux?.webContentsView?.onEvent;
    if (!subscribe) return;
    const unsubscribe = subscribe(
      viewHandle.id,
      (event: ElectronWebContentsEvent) => {
        if (event.type === "state") {
          applyState(event.state);
          return;
        }
        if (event.type === "load-failed" && event.isMainFrame) {
          setLastError(event.errorDescription || "Failed to load page");
        }
      }
    );
    return () => {
      unsubscribe?.();
    };
  }, [applyState, viewHandle]);

  const handleViewReady = useCallback((info: NativeViewHandle) => {
    setViewHandle(info);
    setLastError(null);
  }, []);

  const handleViewDestroyed = useCallback(() => {
    setViewHandle(null);
    setIsLoading(false);
    setDevtoolsOpen(false);
    setCanGoBack(false);
    setCanGoForward(false);
  }, []);

  const handleSubmit = useCallback(
    (event: React.FormEvent<HTMLFormElement>) => {
      event.preventDefault();
      if (!viewHandle) return;
      const raw = addressValue.trim();
      if (!raw) return;
      const target = normalizeUrl(raw);
      setCommittedUrl(target);
      setAddressValue(target);
      setLastError(null);
      setIsEditing(false);
      inputRef.current?.blur();
      void window.cmux?.webContentsView
        ?.loadURL(viewHandle.id, target)
        .catch((error: unknown) => {
          console.warn("Failed to navigate WebContentsView", error);
        });
    },
    [addressValue, viewHandle]
  );

  const handleInputFocus = useCallback(
    (event: React.FocusEvent<HTMLInputElement>) => {
      setIsEditing(true);
      event.currentTarget.select();
    },
    []
  );

  const handleInputBlur = useCallback(
    (event: React.FocusEvent<HTMLInputElement>) => {
      setIsEditing(false);
      setAddressValue(committedUrl);
      const input = event.currentTarget;
      queueMicrotask(() => {
        try {
          const end = input.value.length;
          input.setSelectionRange?.(end, end);
          input.selectionStart = end;
          input.selectionEnd = end;
        } catch {
          // Ignore selection errors on older browsers.
        }
        if (typeof window !== "undefined") {
          window.getSelection?.()?.removeAllRanges?.();
        }
      });
    },
    [committedUrl]
  );

  const handleInputMouseUp = useCallback(
    (event: React.MouseEvent<HTMLInputElement>) => {
      if (document.activeElement !== event.currentTarget) {
        return;
      }
      event.currentTarget.select();
    },
    []
  );

  const handleInputKeyDown = useCallback(
    (event: React.KeyboardEvent<HTMLInputElement>) => {
      if (event.key === "Escape") {
        event.preventDefault();
        event.currentTarget.blur();
        setAddressValue(committedUrl);
      }
    },
    [committedUrl]
  );

  const handleToggleDevTools = useCallback(() => {
    if (!viewHandle) return;
    if (devtoolsOpen) {
      void window.cmux?.webContentsView
        ?.closeDevTools(viewHandle.id)
        .catch((error: unknown) => {
          console.warn("Failed to close DevTools", error);
        });
    } else {
      void window.cmux?.webContentsView
        ?.openDevTools(viewHandle.id, { mode: devtoolsMode })
        .catch((error: unknown) => {
          console.warn("Failed to open DevTools", error);
        });
    }
  }, [devtoolsMode, devtoolsOpen, viewHandle]);

  const handleGoBack = useCallback(() => {
    if (!viewHandle) return;
    void window.cmux?.webContentsView
      ?.goBack(viewHandle.id)
      .catch((error: unknown) => {
        console.warn("Failed to go back", error);
      });
  }, [viewHandle]);

  const handleGoForward = useCallback(() => {
    if (!viewHandle) return;
    void window.cmux?.webContentsView
      ?.goForward(viewHandle.id)
      .catch((error: unknown) => {
        console.warn("Failed to go forward", error);
      });
  }, [viewHandle]);

  const devtoolsTooltipLabel = devtoolsOpen
    ? "Close DevTools"
    : "Open DevTools";

  const progressStyles = useMemo(() => {
    return {
      width: `${Math.min(1, Math.max(progress, 0)) * 100}%`,
      opacity: visible ? 1 : 0,
    } satisfies CSSProperties;
  }, [progress, visible]);

  return (
    <div className="flex h-full flex-col">
      <div className="">
        <form onSubmit={handleSubmit} className="flex flex-col gap-2">
          <div
            className={cn(
              "relative flex items-center gap-2 border border-neutral-200 bg-white px-3 font-mono",
              "dark:border-neutral-800 dark:bg-neutral-900"
            )}
          >
            <div className="flex items-center gap-1">
              <Tooltip>
                <TooltipTrigger asChild>
                  <Button
                    type="button"
                    variant="ghost"
                    size="icon"
                    className="size-7 rounded-full p-0 text-neutral-600 hover:text-neutral-800 disabled:opacity-30 disabled:hover:text-neutral-400 dark:text-neutral-500 dark:hover:text-neutral-100 dark:disabled:hover:text-neutral-500"
                    onClick={handleGoBack}
                    disabled={!viewHandle || !canGoBack}
                    aria-label="Go back"
                  >
                    <ArrowLeft className="size-4" />
                  </Button>
                </TooltipTrigger>
                <TooltipContent side="bottom">Back</TooltipContent>
              </Tooltip>
              <Tooltip>
                <TooltipTrigger asChild>
                  <Button
                    type="button"
                    variant="ghost"
                    size="icon"
                    className="size-7 rounded-full p-0 text-neutral-600 hover:text-neutral-800 disabled:opacity-30 disabled:hover:text-neutral-400 dark:text-neutral-500 dark:hover:text-neutral-100 dark:disabled:hover:text-neutral-500"
                    onClick={handleGoForward}
                    disabled={!viewHandle || !canGoForward}
                    aria-label="Go forward"
                  >
                    <ArrowRight className="size-4" />
                  </Button>
                </TooltipTrigger>
                <TooltipContent side="bottom">Forward</TooltipContent>
              </Tooltip>
              <Tooltip>
                <TooltipTrigger asChild>
                  <Button
                    type="button"
                    variant="ghost"
                    size="icon"
                    className="size-7 rounded-full p-0 text-neutral-600 hover:text-neutral-800 disabled:opacity-30 disabled:hover:text-neutral-400 dark:text-neutral-500 dark:hover:text-neutral-100 dark:disabled:hover:text-neutral-500"
                    onClick={() => {
                      if (!viewHandle) return;
                      void window.cmux?.webContentsView
                        ?.reload(viewHandle.id)
                        .catch((error: unknown) => {
                          console.warn(
                            "Failed to reload WebContentsView",
                            error
                          );
                        });
                    }}
                    disabled={!viewHandle}
                    aria-label="Refresh page"
                  >
                    {isLoading ? (
                      <Loader2 className="size-4 animate-spin text-primary" />
                    ) : (
                      <RefreshCw className="size-4" />
                    )}
                  </Button>
                </TooltipTrigger>
                <TooltipContent side="bottom">Refresh</TooltipContent>
              </Tooltip>
            </div>
            <input
              ref={inputRef}
              value={addressValue}
              onChange={(event) => setAddressValue(event.target.value)}
              onFocus={handleInputFocus}
              onBlur={handleInputBlur}
              onMouseUp={handleInputMouseUp}
              onKeyDown={handleInputKeyDown}
              className="flex-1 bg-transparent text-[11px] text-neutral-900 outline-none placeholder:text-neutral-400 disabled:cursor-not-allowed disabled:text-neutral-400 dark:text-neutral-100 dark:placeholder:text-neutral-600"
              placeholder="Enter a URL"
              spellCheck={false}
              autoCapitalize="none"
              autoCorrect="off"
              disabled={!viewHandle}
            />
            <div className="flex items-center gap-1">
              <Tooltip>
                <TooltipTrigger asChild>
                  <Button
                    type="button"
                    variant="ghost"
                    size="icon"
                    className={clsx(
                      "size-7 rounded-full p-0 text-neutral-600 hover:text-neutral-800 disabled:opacity-30 disabled:hover:text-neutral-400 dark:text-neutral-500 dark:hover:text-neutral-100 dark:disabled:hover:text-neutral-500",
                      devtoolsOpen && "text-primary hover:text-primary"
                    )}
                    onClick={handleToggleDevTools}
                    disabled={!viewHandle}
                    aria-label={devtoolsTooltipLabel}
                  >
                    <Inspect className="size-4" />
                  </Button>
                </TooltipTrigger>
                <TooltipContent side="bottom" align="end">
                  {devtoolsTooltipLabel}
                </TooltipContent>
              </Tooltip>
            </div>
            <div
              className="pointer-events-none absolute inset-x-0 -top-px h-[2px] overflow-hidden bg-neutral-200/70 transition-opacity duration-500 dark:bg-neutral-800/80"
              style={{ opacity: visible ? 1 : 0 }}
            >
              <div
                className="h-full rounded-full bg-primary transition-[opacity,width]"
                style={progressStyles}
              />
            </div>
          </div>
        </form>
        {lastError ? (
          <div className="mt-2 rounded-md border border-destructive/30 bg-destructive/10 px-3 py-2 text-xs text-destructive dark:border-red-700/40 dark:bg-red-500/15">
            Failed to load page: {lastError}
          </div>
        ) : null}
      </div>
      <div className="flex-1 overflow-hidden bg-white dark:bg-neutral-950">
        <PersistentWebView
          persistKey={persistKey}
          src={src}
          className="h-full w-full border-0"
          borderRadius={0}
          sandbox="allow-same-origin allow-scripts allow-popups allow-forms allow-modals allow-downloads"
          onElectronViewReady={handleViewReady}
          onElectronViewDestroyed={handleViewDestroyed}
        />
      </div>
    </div>
  );
}
