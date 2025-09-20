import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import type { CSSProperties, ReactNode } from "react";

import { isElectron } from "@/lib/electron";
import { cn } from "@/lib/utils";

interface ElectronWebContentsViewProps {
  src: string;
  className?: string;
  style?: CSSProperties;
  backgroundColor?: string;
  fallback?: ReactNode;
  borderRadius?: number;
  suspended?: boolean;
  persistKey?: string;
  retainOnUnmount?: boolean;
  onNativeViewReady?: (info: {
    id: number;
    webContentsId: number;
    restored: boolean;
  }) => void;
  onNativeViewDestroyed?: () => void;
}

interface BoundsPayload {
  x: number;
  y: number;
  width: number;
  height: number;
}

interface SyncState {
  bounds: BoundsPayload;
  visible: boolean;
}

function getWebContentsBridge() {
  if (typeof window === "undefined") return null;
  return window.cmux?.webContentsView ?? null;
}

function debugLog(message: string, payload?: Record<string, unknown>) {
  if (process.env.NODE_ENV === "development") {
    console.log("[electron-web-contents-view]", message, payload ?? {});
  } else {
    console.log("[electron-web-contents-view]", message, payload ?? {});
  }
}

function rectToBounds(rect: DOMRect): BoundsPayload {
  return {
    x: Math.round(rect.left),
    y: Math.round(rect.top),
    width: Math.max(0, Math.round(rect.width)),
    height: Math.max(0, Math.round(rect.height)),
  };
}

const pendingReleases = new Map<string, Promise<void>>();
const pendingCreates = new Map<string, Promise<void>>();

export function ElectronWebContentsView({
  src,
  className,
  style,
  backgroundColor,
  fallback,
  borderRadius,
  suspended = false,
  persistKey,
  retainOnUnmount: _retainOnUnmount,
  onNativeViewReady,
  onNativeViewDestroyed,
}: ElectronWebContentsViewProps) {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const viewIdRef = useRef<number | null>(null);
  const rafRef = useRef<number | null>(null);
  const lastSyncRef = useRef<SyncState | null>(null);
  const latestSrcRef = useRef(src);
  const lastLoadedSrcRef = useRef<string | null>(null);
  const latestStyleRef = useRef<{ backgroundColor?: string; borderRadius?: number }>({
    backgroundColor,
    borderRadius,
  });
  const hasStableAttachmentRef = useRef(false);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  useEffect(() => {
    latestSrcRef.current = src;
  }, [src]);

  useEffect(() => {
    latestStyleRef.current = { backgroundColor, borderRadius };
  }, [backgroundColor, borderRadius]);

  const cancelScheduledSync = useCallback(() => {
    if (rafRef.current !== null) {
      cancelAnimationFrame(rafRef.current);
      rafRef.current = null;
    }
  }, []);

  const syncBounds = useCallback(() => {
    if (!isElectron) return;
    const bridge = getWebContentsBridge();
    const id = viewIdRef.current;
    const container = containerRef.current;
    if (!bridge || id === null || !container) return;

    const rect = container.getBoundingClientRect();
    const bounds = rectToBounds(rect);
    const visible = !suspended && bounds.width > 0 && bounds.height > 0;
    const prev = lastSyncRef.current;
    if (
      prev &&
      prev.visible === visible &&
      prev.bounds.x === bounds.x &&
      prev.bounds.y === bounds.y &&
      prev.bounds.width === bounds.width &&
      prev.bounds.height === bounds.height
    ) {
      return;
    }

    void bridge
      .setBounds({ id, bounds, visible })
      .catch((err) => console.warn("Failed to sync WebContentsView bounds", err));
    lastSyncRef.current = { bounds, visible };
  }, [suspended]);

  const scheduleBoundsSync = useCallback(() => {
    if (!isElectron) return;
    if (rafRef.current !== null) return;
    rafRef.current = window.requestAnimationFrame(() => {
      rafRef.current = null;
      syncBounds();
    });
  }, [syncBounds]);

  const persistKeyRef = useRef<string | undefined>(persistKey);

  persistKeyRef.current = persistKey;

  const releaseNativeView = useCallback((id: number, key: string | undefined) => {
    const bridge = getWebContentsBridge();
    if (!bridge) return;

    const persistKey = typeof key === "string" && key.length > 0 ? key : undefined;

    debugLog("release-native-view", {
      id,
      persistKey,
    });

    const releaseTask = (async () => {
      if (typeof bridge.release === "function") {
        try {
          debugLog("requesting-release", { id, persistKey });
          await bridge.release({ id, persist: true });
          debugLog("release-requested", { id, persistKey });
          return;
        } catch (err) {
          console.warn("Failed to release WebContentsView", err);
        }
      }

      try {
        debugLog("destroying-native-view", { id, persistKey });
        await bridge.destroy(id);
      } catch (err) {
        console.warn("Failed to destroy WebContentsView", err);
      }
    })();

    if (persistKey) {
      const tracked = releaseTask.finally(() => {
        if (pendingReleases.get(persistKey) === tracked) {
          pendingReleases.delete(persistKey);
        }
      });
      pendingReleases.set(persistKey, tracked);
      void tracked.catch(() => undefined);
    } else {
      void releaseTask.catch(() => undefined);
    }
  }, []);

  const releaseView = useCallback(() => {
    cancelScheduledSync();
    const id = viewIdRef.current;
    if (id === null) return;
    viewIdRef.current = null;
    lastSyncRef.current = null;
    lastLoadedSrcRef.current = null;
    hasStableAttachmentRef.current = false;
    releaseNativeView(id, persistKeyRef.current);
    onNativeViewDestroyed?.();
  }, [cancelScheduledSync, onNativeViewDestroyed, releaseNativeView]);

  useEffect(() => {
    if (!isElectron) return undefined;
    const container = containerRef.current;
    if (!container) return undefined;
    const bridge = getWebContentsBridge();
    if (!bridge) return undefined;

    let disposed = false;
    setErrorMessage(null);

    const initialBounds = rectToBounds(container.getBoundingClientRect());
    const { backgroundColor: initialBackground, borderRadius: initialRadius } = latestStyleRef.current;

    const key = persistKeyRef.current;
    const pendingRelease = key ? pendingReleases.get(key) : undefined;
    const pendingCreate = key ? pendingCreates.get(key) : undefined;

    const performCreate = async () => {
      if (pendingCreate) {
        debugLog("awaiting-pending-create", { persistKey: key });
        try {
          await pendingCreate;
        } catch {
          // ignore failures from previous create attempts
        }
      }

      if (pendingRelease) {
        debugLog("awaiting-pending-release", { persistKey: key });
        try {
          await pendingRelease;
        } catch {
          // ignore pending release failures; we'll attempt to create regardless
        }
      }

      const createTask = (async () => {
        try {
          debugLog("creating-native-view", {
            persistKey: key,
            url: latestSrcRef.current,
            bounds: initialBounds,
          });
          const result = await bridge.create({
            url: latestSrcRef.current,
            bounds: initialBounds,
            backgroundColor: initialBackground,
            borderRadius: initialRadius,
            persistKey: key,
          });

          if (disposed) {
            debugLog("create-result-after-dispose", { id: result.id, persistKey: key });
            releaseNativeView(result.id, persistKeyRef.current);
            return;
          }
          debugLog("create-result", {
            id: result.id,
            persistKey: key,
            restored: result.restored,
          });
          viewIdRef.current = result.id;
          hasStableAttachmentRef.current = true;
          onNativeViewReady?.(result);
          const targetUrl = latestSrcRef.current;
          if (!result.restored) {
            void bridge
              .loadURL(result.id, targetUrl)
              .then(() => {
                debugLog("load-url-complete", {
                  id: result.id,
                  persistKey: key,
                  url: targetUrl,
                });
                lastLoadedSrcRef.current = targetUrl;
              })
              .catch((err) => console.warn("Failed to load URL after create", err));
          } else {
            debugLog("restored-native-view", {
              id: result.id,
              persistKey: key,
              url: targetUrl,
            });
            lastLoadedSrcRef.current = targetUrl;
          }
          scheduleBoundsSync();
        } catch (err) {
          console.error("Failed to create WebContentsView", err);
          setErrorMessage("Unable to create Electron WebContentsView");
          onNativeViewDestroyed?.();
        }
      })();

      if (key) {
        const trackedCreate = createTask.finally(() => {
          if (pendingCreates.get(key) === trackedCreate) {
            pendingCreates.delete(key);
          }
        });
        pendingCreates.set(key, trackedCreate);
      }

      await createTask;
    };

    void performCreate();

    return () => {
      disposed = true;
      releaseView();
    };
  }, [
    persistKey,
    releaseNativeView,
    releaseView,
    scheduleBoundsSync,
    onNativeViewDestroyed,
    onNativeViewReady,
  ]);

  useEffect(() => {
    if (!isElectron) return;
    const bridge = getWebContentsBridge();
    const id = viewIdRef.current;
    if (!bridge || id === null) return;
    if (lastLoadedSrcRef.current === src) return;
    debugLog("load-url-request", { id, url: src, persistKey: persistKeyRef.current });
    void bridge
      .loadURL(id, src)
      .then(() => {
        debugLog("load-url-after-update", {
          id,
          persistKey: persistKeyRef.current,
          url: src,
        });
        lastLoadedSrcRef.current = src;
      })
      .catch((err) => console.warn("Failed to load URL in WebContentsView", err));
  }, [src]);

  useEffect(() => {
    if (!isElectron) return;
    const bridge = getWebContentsBridge();
    const id = viewIdRef.current;
    if (!bridge || id === null) return;
    if (backgroundColor === undefined && borderRadius === undefined) return;
    void bridge
      .updateStyle({ id, backgroundColor, borderRadius })
      .catch((err) => console.warn("Failed to update WebContentsView style", err));
  }, [backgroundColor, borderRadius]);

  useEffect(() => {
    if (!isElectron) return undefined;
    const container = containerRef.current;
    if (!container) return undefined;

    scheduleBoundsSync();

    let resizeObserver: ResizeObserver | null = null;
    if (typeof ResizeObserver !== "undefined") {
      resizeObserver = new ResizeObserver(() => {
        scheduleBoundsSync();
      });
      resizeObserver.observe(container);
    }

    const handleScroll = () => {
      scheduleBoundsSync();
    };

    window.addEventListener("scroll", handleScroll, true);
    window.addEventListener("resize", handleScroll);

    let mutationObserver: MutationObserver | null = null;
    if (typeof MutationObserver !== "undefined") {
      mutationObserver = new MutationObserver(() => {
        scheduleBoundsSync();
      });
      const observed: HTMLElement[] = [];
      let node: HTMLElement | null = container;
      while (node) {
        mutationObserver.observe(node, {
          attributes: true,
          attributeFilter: ["style", "class"],
        });
        observed.push(node);
        node = node.parentElement;
      }
    }

    return () => {
      resizeObserver?.disconnect();
      window.removeEventListener("scroll", handleScroll, true);
      window.removeEventListener("resize", handleScroll);
      mutationObserver?.disconnect();
    };
  }, [scheduleBoundsSync]);

  useLayoutEffect(() => {
    if (!isElectron) return;
    scheduleBoundsSync();
  }, [scheduleBoundsSync]);

  useEffect(() => {
    if (!isElectron) return;
    scheduleBoundsSync();
  }, [scheduleBoundsSync, suspended]);

  const shouldShowFallback = !isElectron || errorMessage !== null;

  return (
    <div
      ref={containerRef}
      className={cn("relative h-full w-full", className)}
      style={{ ...style, borderRadius }}
      data-role="electron-web-contents-view"
      data-suspended={suspended ? "true" : "false"}
    >
      {shouldShowFallback ? (
        <div className="flex h-full w-full items-center justify-center rounded-md border border-dashed border-neutral-300 bg-white/80 text-sm text-neutral-600 dark:border-neutral-700 dark:bg-neutral-900/80 dark:text-neutral-300">
          {errorMessage ?? fallback ?? "Open this view in the Electron app to see the embedded page."}
        </div>
      ) : null}
    </div>
  );
}
