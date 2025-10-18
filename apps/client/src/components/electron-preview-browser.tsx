import {
  ArrowLeft,
  ArrowRight,
  Inspect,
  Loader2,
  RefreshCw,
  TerminalSquare,
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
  showTerminal?: boolean;
  onToggleTerminal?: () => void;
  onErrorStateChange?: (isError: boolean) => void;
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
    let hideTimeout: ReturnType<typeof setTimeout> | null = null;
    let resetTimeout: ReturnType<typeof setTimeout> | null = null;

    if (isLoading) {
      setVisible(true);
      setProgress((prev) => {
        if (prev <= 0 || prev >= 1) {
          return 0.08;
        }
        return prev;
      });
      interval = setInterval(() => {
        setProgress((prev) => {
          const next = prev + (1 - prev) * 0.18;
          return Math.min(next, 0.95);
        });
      }, 120);
    } else {
      setProgress((prev) => (prev === 0 ? 0 : 1));
      hideTimeout = setTimeout(() => {
        setVisible(false);
        resetTimeout = setTimeout(() => {
          setProgress(0);
        }, 500);
      }, 300);
    }

    return () => {
      if (interval) clearInterval(interval);
      if (hideTimeout) clearTimeout(hideTimeout);
      if (resetTimeout) clearTimeout(resetTimeout);
    };
  }, [isLoading]);

  return { progress, visible };
}

export function ElectronPreviewBrowser({
  persistKey,
  src,
  showTerminal = false,
  onToggleTerminal,
  onErrorStateChange,
}: ElectronPreviewBrowserProps) {
  const [viewHandle, setViewHandle] = useState<NativeViewHandle | null>(null);
  const [addressValue, setAddressValue] = useState(src);
  const [committedUrl, setCommittedUrl] = useState(src);
  const [isEditing, setIsEditing] = useState(false);
  const [isLoading, setIsLoading] = useState(false);
  const [devtoolsOpen, setDevtoolsOpen] = useState(false);
  const [devtoolsMode] = useState<ElectronDevToolsMode>("right");
  const [canGoBack, setCanGoBack] = useState(false);
  const [canGoForward, setCanGoForward] = useState(false);
  const [isShowingErrorPage, setIsShowingErrorPage] = useState(false);
  const inputRef = useRef<HTMLInputElement | null>(null);
  const isNavigatingRef = useRef(false);
  const pendingRefocusTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(
    null,
  );
  const windowHasFocusRef = useRef(
    typeof document !== "undefined" ? document.hasFocus() : true,
  );

  const { progress, visible } = useLoadingProgress(isLoading);

  useEffect(() => {
    setAddressValue(src);
    setCommittedUrl(src);
    setCanGoBack(false);
    setCanGoForward(false);
  }, [src]);

  const applyState = useCallback(
    (state: ElectronWebContentsState, reason?: string) => {
      console.log("[ElectronPreviewBrowser] applyState", { state, reason });

      // Check if this is the error page - preserve original URL in address bar
      let displayUrl = state.url;
      let showingError = false;
      try {
        const url = new URL(state.url);
        if (url.pathname === "/electron-error") {
          showingError = true;
          const originalUrl = url.searchParams.get("url");
          if (originalUrl) {
            displayUrl = originalUrl;
          }
        }
      } catch {
        // Invalid URL, use as-is
      }

      setIsShowingErrorPage(showingError);
      onErrorStateChange?.(showingError);

      const hasDisplayUrl = displayUrl.trim().length > 0;

      if (hasDisplayUrl) {
        setCommittedUrl(displayUrl);
        if (!isEditing) {
          setAddressValue(displayUrl);
        }
      }
      setIsLoading(state.isLoading);
      setDevtoolsOpen(state.isDevToolsOpened);
      setCanGoBack(Boolean(state.canGoBack));
      setCanGoForward(Boolean(state.canGoForward));

      // Clear navigation flag when loading starts
      if (state.isLoading && isNavigatingRef.current) {
        isNavigatingRef.current = false;
      }
    },
    [isEditing, onErrorStateChange],
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
        console.log("[ElectronPreviewBrowser] Event", event);
        if (event.type === "state") {
          applyState(event.state, event.reason);
          return;
        }
      },
    );
    return () => {
      unsubscribe?.();
    };
  }, [applyState, viewHandle]);

  const handleViewReady = useCallback((info: NativeViewHandle) => {
    setViewHandle(info);
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
      setIsEditing(false);
      isNavigatingRef.current = true;
      inputRef.current?.blur();
      void window.cmux?.webContentsView
        ?.loadURL(viewHandle.id, target)
        .catch((error: unknown) => {
          console.warn("Failed to navigate WebContentsView", error);
        });
    },
    [addressValue, viewHandle],
  );

  const initialSelectHandled = useRef(false);
  const inputFocused = useRef(false);

  const handleInputFocus = useCallback(
    (_event: React.FocusEvent<HTMLInputElement>) => {
      setIsEditing(true);
      inputFocused.current = true;
      // event.currentTarget.select();
    },
    [],
  );

  const handleInputBlur = useCallback(
    (event: React.FocusEvent<HTMLInputElement>) => {
      initialSelectHandled.current = false;
      inputFocused.current = false;
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

      // Only refocus WebContentsView if:
      // 1. Focus isn't going to another UI element
      // 2. The window still has focus (not cmd+tabbing away)
      // 3. We're not in the middle of navigating (user just submitted URL)
      const focusGoingToUIElement = event.relatedTarget instanceof HTMLElement;

      // Clear any existing pending refocus
      if (pendingRefocusTimeoutRef.current !== null) {
        clearTimeout(pendingRefocusTimeoutRef.current);
        pendingRefocusTimeoutRef.current = null;
      }

      if (viewHandle && !focusGoingToUIElement && !isNavigatingRef.current) {
        // Wait a tick to let focus settle, then check if window still has focus
        pendingRefocusTimeoutRef.current = setTimeout(() => {
          pendingRefocusTimeoutRef.current = null;
          if (!windowHasFocusRef.current) {
            return;
          }
          if (typeof document === "undefined") {
            return;
          }
          if (document.visibilityState !== "visible") {
            return;
          }

          // Double-check after a small delay to ensure we're really focused
          // This handles the edge case where blur happens during alt-tab
          setTimeout(() => {
            // Recheck all conditions to avoid refocusing if user alt-tabbed
            if (
              !windowHasFocusRef.current ||
              document.visibilityState !== "visible" ||
              !document.hasFocus()
            ) {
              return;
            }

            // Check if any interactive element gained focus in the meantime
            const activeElement = document.activeElement;
            const isInteractiveElementFocused =
              activeElement instanceof HTMLInputElement ||
              activeElement instanceof HTMLTextAreaElement ||
              activeElement instanceof HTMLButtonElement ||
              activeElement instanceof HTMLSelectElement ||
              (activeElement instanceof HTMLElement &&
                activeElement.isContentEditable);

            if (!isInteractiveElementFocused) {
              void window.cmux?.ui
                ?.focusWebContents(viewHandle.webContentsId)
                .catch((error: unknown) => {
                  console.warn(
                    "Failed to refocus WebContentsView on blur",
                    error,
                  );
                });
            }
          }, 100); // Wait 100ms to ensure focus state has settled
        }, 0);
      }
    },
    [committedUrl, viewHandle],
  );

  const handleInputMouseUp = useCallback(
    (event: React.MouseEvent<HTMLInputElement>) => {
      if (initialSelectHandled.current) {
        return;
      }
      initialSelectHandled.current = true;
      event.currentTarget.select();
    },
    [],
  );

  const handleInputKeyDown = useCallback(
    (event: React.KeyboardEvent<HTMLInputElement>) => {
      if (event.key === "Escape") {
        event.preventDefault();
        setAddressValue(committedUrl);
        event.currentTarget.blur();
        // Blur will handle refocusing the WebContentsView
      }
    },
    [committedUrl],
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
    isNavigatingRef.current = true;
    void window.cmux?.webContentsView
      ?.goBack(viewHandle.id)
      .catch((error: unknown) => {
        console.warn("Failed to go back", error);
      });
  }, [viewHandle]);

  useEffect(() => {
    if (typeof document === "undefined") return;

    const handleVisibilityChange = () => {
      const isVisible = document.visibilityState === "visible";
      if (!isVisible) {
        windowHasFocusRef.current = false;
        if (pendingRefocusTimeoutRef.current !== null) {
          clearTimeout(pendingRefocusTimeoutRef.current);
          pendingRefocusTimeoutRef.current = null;
        }
        return;
      }
      windowHasFocusRef.current = document.hasFocus();
    };

    document.addEventListener("visibilitychange", handleVisibilityChange);
    return () => {
      document.removeEventListener("visibilitychange", handleVisibilityChange);
    };
  }, []);

  const handleGoForward = useCallback(() => {
    if (!viewHandle) return;
    isNavigatingRef.current = true;
    void window.cmux?.webContentsView
      ?.goForward(viewHandle.id)
      .catch((error: unknown) => {
        console.warn("Failed to go forward", error);
      });
  }, [viewHandle]);

  const reloadCurrentView = useCallback(() => {
    if (viewHandle) {
      isNavigatingRef.current = true;
      // If showing error page, retry the original URL instead of reloading error page
      if (isShowingErrorPage && committedUrl) {
        void window.cmux?.webContentsView
          ?.loadURL(viewHandle.id, committedUrl)
          .catch((error: unknown) => {
            console.warn("Failed to retry URL", error);
          });
      } else {
        void window.cmux?.webContentsView
          ?.reload(viewHandle.id)
          .catch((error: unknown) => {
            console.warn("Failed to reload WebContentsView", error);
          });
      }
      return;
    }

    if (typeof document === "undefined") {
      return;
    }

    const escapedKey =
      typeof CSS !== "undefined" && typeof CSS.escape === "function"
        ? CSS.escape(persistKey)
        : persistKey.replace(/"/g, '\\"');
    const iframe = document.querySelector<HTMLIFrameElement>(
      `[data-iframe-key="${escapedKey}"] iframe`,
    );
    if (!iframe?.contentWindow) {
      return;
    }
    try {
      iframe.contentWindow.location.reload();
    } catch (error) {
      console.warn("Failed to reload iframe view", error);
    }
  }, [committedUrl, isShowingErrorPage, persistKey, viewHandle]);

  useEffect(() => {
    if (typeof window === "undefined") return;
    const off = window.cmux?.on?.("shortcut:preview-reload", () => {
      reloadCurrentView();
    });
    return () => {
      off?.();
    };
  }, [reloadCurrentView]);

  useEffect(() => {
    if (typeof window === "undefined") return;
    const off = window.cmux?.on?.("shortcut:preview-back", () => {
      handleGoBack();
    });
    return () => {
      off?.();
    };
  }, [handleGoBack]);

  useEffect(() => {
    if (typeof window === "undefined") return;
    const off = window.cmux?.on?.("shortcut:preview-forward", () => {
      handleGoForward();
    });
    return () => {
      off?.();
    };
  }, [handleGoForward]);

  useEffect(() => {
    if (typeof window === "undefined") return;
    let rafId: number | null = null;
    let timeoutId: ReturnType<typeof setTimeout> | null = null;

    const off = window.cmux?.on?.(
      "shortcut:preview-focus-address",
      async () => {
        // Clean up any pending focus operations
        if (rafId !== null) cancelAnimationFrame(rafId);
        if (timeoutId !== null) clearTimeout(timeoutId);

        // Focus the main window first to take focus away from WebContentsView
        try {
          const currentWebContentsId = window.cmux?.getCurrentWebContentsId?.();
          if (currentWebContentsId) {
            await window.cmux?.ui?.focusWebContents(currentWebContentsId);
          }
        } catch (error) {
          console.warn("Failed to focus main window webContents", error);
        }

        // Wait for focus to fully transfer, then focus and select the input
        // Use multiple strategies to ensure it works
        const focusInput = () => {
          if (inputRef.current) {
            inputRef.current.focus();
            inputRef.current.select();
          }
        };

        // Try immediately
        focusInput();

        // Try again after animation frame (ensures DOM has updated)
        rafId = requestAnimationFrame(() => {
          focusInput();
          // And one more time after a small delay to handle slow focus transfers
          timeoutId = setTimeout(focusInput, 50);
        });
      },
    );

    return () => {
      off?.();
      if (rafId !== null) cancelAnimationFrame(rafId);
      if (timeoutId !== null) clearTimeout(timeoutId);
    };
  }, []);

  useEffect(() => {
    if (typeof window === "undefined") return;
    const show = window.cmux?.ui?.setPreviewReloadVisible;
    if (show) {
      void show(true).catch((error: unknown) => {
        console.warn("Failed to show preview reload menu item", error);
      });
    }
    return () => {
      const hide = window.cmux?.ui?.setPreviewReloadVisible;
      if (hide) {
        void hide(false).catch((error: unknown) => {
          console.warn("Failed to hide preview reload menu item", error);
        });
      }
    };
  }, []);

  // Track window focus/blur state and cancel pending refocus on blur
  useEffect(() => {
    if (typeof window === "undefined") return;

    const handleWindowFocus = () => {
      // Wait a moment to ensure focus state has stabilized
      setTimeout(() => {
        if (typeof document === "undefined") {
          return;
        }

        // Only update focus state if document is actually visible and focused
        if (document.visibilityState === "visible" && document.hasFocus()) {
          windowHasFocusRef.current = true;

          // Give the browser more time to restore natural focus
          // This prevents premature refocusing when switching between apps
          setTimeout(() => {
            if (typeof document === "undefined") {
              return;
            }

            // Double-check that we're still focused after the delay
            // This prevents focus stealing when rapidly switching apps
            if (
              !document.hasFocus() ||
              document.visibilityState !== "visible"
            ) {
              windowHasFocusRef.current = false;
              return;
            }

            // If no input/button/etc has focus, refocus the WebContentsView
            const activeElement = document.activeElement;
            const isInteractiveElementFocused =
              activeElement instanceof HTMLInputElement ||
              activeElement instanceof HTMLTextAreaElement ||
              activeElement instanceof HTMLButtonElement ||
              activeElement instanceof HTMLSelectElement ||
              (activeElement instanceof HTMLElement &&
                activeElement.isContentEditable);

            if (
              !isInteractiveElementFocused &&
              viewHandle &&
              windowHasFocusRef.current
            ) {
              void window.cmux?.ui
                ?.focusWebContents(viewHandle.webContentsId)
                .catch((error: unknown) => {
                  console.warn(
                    "Failed to refocus WebContentsView on window focus",
                    error,
                  );
                });
            }
          }, 150); // Increased delay to ensure focus has settled
        } else {
          windowHasFocusRef.current = false;
        }
      }, 10);
    };

    const handleWindowBlur = () => {
      windowHasFocusRef.current = false;
      // Cancel any pending refocus operations when window loses focus
      if (pendingRefocusTimeoutRef.current !== null) {
        clearTimeout(pendingRefocusTimeoutRef.current);
        pendingRefocusTimeoutRef.current = null;
      }
    };

    window.addEventListener("focus", handleWindowFocus);
    window.addEventListener("blur", handleWindowBlur);
    return () => {
      window.removeEventListener("focus", handleWindowFocus);
      window.removeEventListener("blur", handleWindowBlur);
      // Clean up any pending refocus on unmount
      if (pendingRefocusTimeoutRef.current !== null) {
        clearTimeout(pendingRefocusTimeoutRef.current);
        pendingRefocusTimeoutRef.current = null;
      }
    };
  }, [viewHandle]);

  const devtoolsTooltipLabel = devtoolsOpen
    ? "Close DevTools"
    : "Open DevTools";

  const progressStyles = useMemo(() => {
    return {
      width: `${Math.min(1, Math.max(progress, 0)) * 100}%`,
    } satisfies CSSProperties;
  }, [progress]);

  return (
    <div className="flex h-full flex-col">
      <div className="">
        <form onSubmit={handleSubmit} className="flex flex-col gap-2">
          <div
            className={cn(
              "relative flex items-center gap-1 border border-neutral-200 bg-white px-2 pt-0.5 pb-[3px]",
              "dark:border-neutral-800 dark:bg-neutral-900",
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
                    onClick={reloadCurrentView}
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
              className="flex-1 bg-neutral-200 dark:bg-neutral-700 px-2 py-px rounded-[5px] text-[13px] text-neutral-800 outline-none placeholder:text-neutral-400 disabled:cursor-not-allowed disabled:text-neutral-400 dark:text-neutral-100 dark:placeholder:text-neutral-600 border-[1.7px] border-transparent active:border-neutral-400 focus:border-neutral-400 dark:active:border-neutral-500 dark:focus:border-neutral-500"
              placeholder="Enter a URL"
              spellCheck={false}
              autoCapitalize="none"
              autoCorrect="off"
              disabled={!viewHandle}
            />
            <div className="flex items-center gap-1">
              {onToggleTerminal && (
                <Tooltip>
                  <TooltipTrigger asChild>
                    <Button
                      type="button"
                      variant="ghost"
                      size="icon"
                      className={clsx(
                        "size-7 rounded-full p-0 text-neutral-600 hover:text-neutral-800 disabled:opacity-30 disabled:hover:text-neutral-400 dark:text-neutral-500 dark:hover:text-neutral-100 dark:disabled:hover:text-neutral-500",
                        showTerminal && "text-primary hover:text-primary",
                      )}
                      onClick={onToggleTerminal}
                      disabled={!viewHandle}
                      aria-label={showTerminal ? "Hide terminal" : "Show terminal"}
                    >
                      <TerminalSquare className="size-4" />
                    </Button>
                  </TooltipTrigger>
                  <TooltipContent side="bottom" align="end">
                    {showTerminal ? "Hide terminal" : "Show terminal"}
                  </TooltipContent>
                </Tooltip>
              )}
              <Tooltip>
                <TooltipTrigger asChild>
                  <Button
                    type="button"
                    variant="ghost"
                    size="icon"
                    className={clsx(
                      "size-7 rounded-full p-0 text-neutral-600 hover:text-neutral-800 disabled:opacity-30 disabled:hover:text-neutral-400 dark:text-neutral-500 dark:hover:text-neutral-100 dark:disabled:hover:text-neutral-500",
                      devtoolsOpen && "text-primary hover:text-primary",
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
              className="pointer-events-none absolute inset-x-0 -top-px h-[1.5px] overflow-hidden transition-opacity duration-300"
              style={{ opacity: visible ? 1 : 0 }}
            >
              <div
                className="h-full rounded-full bg-neutral-900/80 dark:bg-neutral-300 transition-[width] duration-200"
                style={progressStyles}
              />
            </div>
          </div>
        </form>
      </div>
      <div className="flex-1 overflow-hidden bg-white dark:bg-neutral-950 pl-[pxpx] border-l">
        <div className="relative h-full w-full">
          <PersistentWebView
            persistKey={persistKey}
            src={src}
            className="h-full w-full border-0"
            borderRadius={0}
            sandbox="allow-same-origin allow-scripts allow-popups allow-forms allow-modals allow-downloads"
            onElectronViewReady={handleViewReady}
            onElectronViewDestroyed={handleViewDestroyed}
            forceWebContentsViewIfElectron
          />
        </div>
      </div>
    </div>
  );
}
