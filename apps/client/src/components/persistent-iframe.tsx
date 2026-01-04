import {
  type CSSProperties,
  type ReactNode,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { createPortal } from "react-dom";

import { useIframePreflight } from "../hooks/useIframePreflight";
import { usePersistentIframe } from "../hooks/usePersistentIframe";
import {
  registerWebviewActions,
  unregisterWebviewActions,
} from "@/lib/webview-actions";
import { persistentIframeManager } from "@/lib/persistentIframeManager";
import { cn } from "@/lib/utils";

// Stable memoized wrapper className to avoid recreation on every render
const STABLE_IFRAME_CLASSNAMES = new Map<string, string>();
function getStableClassName(className: string | undefined): string | undefined {
  if (!className) return undefined;
  const existing = STABLE_IFRAME_CLASSNAMES.get(className);
  if (existing) return existing;
  STABLE_IFRAME_CLASSNAMES.set(className, className);
  return className;
}

export type PersistentIframeStatus = "loading" | "loaded" | "error";

interface PersistentIframeProps {
  persistKey: string;
  src: string;
  className?: string;
  style?: CSSProperties;
  preload?: boolean;
  allow?: string;
  sandbox?: string;
  iframeClassName?: string;
  iframeStyle?: CSSProperties;
  persistentWrapperClassName?: string;
  persistentWrapperStyle?: CSSProperties;
  onLoad?: () => void;
  onError?: (error: Error) => void;
  loadingFallback?: ReactNode;
  loadingClassName?: string;
  errorFallback?: ReactNode;
  errorClassName?: string;
  onStatusChange?: (status: PersistentIframeStatus) => void;
  forcedStatus?: PersistentIframeStatus | null;
  loadTimeoutMs?: number;
  preflight?: boolean;
  isExpanded?: boolean;
  isAnyPanelExpanded?: boolean;
}

type ScrollTarget = HTMLElement | Window;

function getScrollableParents(element: HTMLElement): ScrollTarget[] {
  const parents: ScrollTarget[] = [];
  let current: HTMLElement | null = element.parentElement;

  while (current) {
    const style = window.getComputedStyle(current);
    if (
      style.overflow === "auto" ||
      style.overflow === "scroll" ||
      style.overflowX === "auto" ||
      style.overflowX === "scroll" ||
      style.overflowY === "auto" ||
      style.overflowY === "scroll"
    ) {
      parents.push(current);
    }
    current = current.parentElement;
  }

  parents.push(window);

  return parents;
}

export function PersistentIframe({
  persistKey,
  src,
  className,
  style,
  preload,
  allow,
  sandbox,
  iframeClassName,
  iframeStyle,
  persistentWrapperClassName,
  persistentWrapperStyle,
  onLoad,
  onError,
  loadingFallback,
  loadingClassName,
  errorFallback,
  errorClassName,
  onStatusChange,
  forcedStatus,
  loadTimeoutMs = 30_000,
  preflight = true,
  isExpanded = false,
  isAnyPanelExpanded = false,
}: PersistentIframeProps) {
  const [status, setStatus] = useState<PersistentIframeStatus>("loading");
  const overlayRef = useRef<HTMLDivElement | null>(null);
  const [, forceRender] = useState(0);
  const loadTimeoutRef = useRef<number | null>(null);
  const preflightErrorRef = useRef<string | null>(null);
  const prevPersistKeyRef = useRef<string>(persistKey);
  const prevSrcRef = useRef<string>(src);

  // Store callbacks in refs to avoid triggering effects on callback changes
  const onLoadRef = useRef(onLoad);
  const onErrorRef = useRef(onError);
  onLoadRef.current = onLoad;
  onErrorRef.current = onError;

  // Only reset to loading when persistKey or src actually changes to a different value
  // This prevents flickering when references change but values are the same
  useEffect(() => {
    const persistKeyChanged = persistKey !== prevPersistKeyRef.current;
    const srcChanged = src !== prevSrcRef.current;

    if (persistKeyChanged || srcChanged) {
      setStatus("loading");
      prevPersistKeyRef.current = persistKey;
      prevSrcRef.current = src;
    }
  }, [persistKey, src]);

  const clearLoadTimeout = useCallback(() => {
    if (loadTimeoutRef.current !== null) {
      window.clearTimeout(loadTimeoutRef.current);
      loadTimeoutRef.current = null;
    }
  }, []);

  // Stable callbacks that use refs - won't trigger effect re-runs
  const handleLoad = useCallback(() => {
    clearLoadTimeout();
    setStatus("loaded");
    onLoadRef.current?.();
  }, [clearLoadTimeout]);

  const handleError = useCallback(
    (error: Error) => {
      clearLoadTimeout();
      setStatus("error");
      onErrorRef.current?.(error);
    },
    [clearLoadTimeout]
  );

  const {
    phase: preflightPhase,
    error: preflightError,
    phasePayload: preflightPhasePayload,
    isMorphTarget: preflightIsMorph,
  } = useIframePreflight({ url: src, enabled: preflight });

  useEffect(() => {
    if (!preflight) {
      preflightErrorRef.current = null;
      return;
    }

    if (preflightError === null) {
      if (preflightPhase === "loading" || preflightPhase === "resuming") {
        preflightErrorRef.current = null;
      }
      return;
    }

    const isFailurePhase =
      preflightPhase === "resume_failed" ||
      preflightPhase === "instance_not_found" ||
      preflightPhase === "preflight_failed" ||
      preflightPhase === "error";

    if (isFailurePhase && preflightErrorRef.current !== preflightError) {
      preflightErrorRef.current = preflightError;
      handleError(new Error(preflightError));
    }
  }, [handleError, preflight, preflightError, preflightPhase]);

  const resumeMessage = useMemo(() => {
    if (!preflight || !preflightIsMorph) {
      return null;
    }

    if (preflightPhase === "resuming") {
      const attempt =
        typeof preflightPhasePayload?.attempt === "number"
          ? preflightPhasePayload.attempt
          : null;
      if (attempt && attempt > 1) {
        return `Retrying workspace resume (attempt ${attempt})…`;
      }
      return "Resuming cloud workspace…";
    }

    if (preflightPhase === "resume_failed") {
      return preflightError ?? "We couldn't resume the workspace.";
    }

    if (preflightPhase === "instance_not_found") {
      return "We couldn't find the workspace instance. Try rerunning the task.";
    }

    if (preflightPhase === "ready" && status === "loading") {
      return "Workspace resumed. Waiting for iframe to load…";
    }

    return null;
  }, [
    preflight,
    preflightError,
    preflightIsMorph,
    preflightPhase,
    preflightPhasePayload,
    status,
  ]);

  // Memoize wrapper className to prevent recreation on every render
  const wrapperClassName = useMemo(
    () => getStableClassName(cn(iframeClassName, persistentWrapperClassName)),
    [iframeClassName, persistentWrapperClassName]
  );

  const wrapperStyle = useMemo(() => {
    if (!iframeStyle && !persistentWrapperStyle) {
      return undefined;
    }
    return {
      ...(iframeStyle ?? {}),
      ...(persistentWrapperStyle ?? {}),
    };
  }, [iframeStyle, persistentWrapperStyle]);

  useEffect(() => {
    if (forcedStatus && forcedStatus !== "loading") {
      clearLoadTimeout();
      return;
    }

    if (status !== "loading") {
      clearLoadTimeout();
      return;
    }

    if (!loadTimeoutMs || loadTimeoutMs <= 0) {
      clearLoadTimeout();
      return;
    }

    loadTimeoutRef.current = window.setTimeout(() => {
      handleError(
        new Error(
          `Timed out loading iframe "${persistKey}" after ${loadTimeoutMs}ms`
        )
      );
    }, loadTimeoutMs);

    return () => {
      clearLoadTimeout();
    };
  }, [
    clearLoadTimeout,
    forcedStatus,
    handleError,
    loadTimeoutMs,
    persistKey,
    status,
  ]);

  const { containerRef } = usePersistentIframe({
    key: persistKey,
    url: src,
    preload,
    allow,
    sandbox,
    className: wrapperClassName,
    style: wrapperStyle,
    onLoad: handleLoad,
    onError: handleError,
  });

  // Hide non-expanded iframes when another panel is expanded
  useEffect(() => {
    const wrapper = document.querySelector(
      `[data-iframe-key="${persistKey}"]`
    ) as HTMLElement;
    if (!wrapper) return;

    if (isAnyPanelExpanded && !isExpanded) {
      // Another panel is expanded - hide this iframe completely
      wrapper.style.visibility = "hidden";
      wrapper.style.pointerEvents = "none";
    } else {
      // This panel is expanded OR no panel is expanded - show normally
      wrapper.style.visibility = "visible";
      wrapper.style.pointerEvents = "auto";
    }
  }, [persistKey, isExpanded, isAnyPanelExpanded]);

  const effectiveStatus = forcedStatus ?? status;

  const focusIframe = useCallback(() => {
    return persistentIframeManager.focusIframe(persistKey);
  }, [persistKey]);

  const isIframeFocused = useCallback(() => {
    return persistentIframeManager.isIframeFocused(persistKey);
  }, [persistKey]);

  useEffect(() => {
    const actions = { focus: focusIframe, isFocused: isIframeFocused };
    registerWebviewActions(persistKey, actions);
    return () => {
      unregisterWebviewActions(persistKey, actions);
    };
  }, [focusIframe, isIframeFocused, persistKey]);

  useEffect(() => {
    onStatusChange?.(effectiveStatus);
  }, [effectiveStatus, onStatusChange]);

  const showLoadingOverlay = effectiveStatus === "loading" && loadingFallback;
  const showErrorOverlay = effectiveStatus === "error" && errorFallback;
  const shouldShowOverlay = Boolean(showLoadingOverlay || showErrorOverlay);

  const syncOverlayPosition = useCallback(() => {
    const overlay = overlayRef.current;
    const target = containerRef.current;
    if (!overlay || !target) return;

    const rect = target.getBoundingClientRect();
    const computedStyle = window.getComputedStyle(target);

    const borderLeft = parseFloat(computedStyle.borderLeftWidth) || 0;
    const borderRight = parseFloat(computedStyle.borderRightWidth) || 0;
    const borderTop = parseFloat(computedStyle.borderTopWidth) || 0;
    const borderBottom = parseFloat(computedStyle.borderBottomWidth) || 0;

    const width = Math.max(0, rect.width - borderLeft - borderRight);
    const height = Math.max(0, rect.height - borderTop - borderBottom);

    if (width < 1 || height < 1) {
      overlay.style.visibility = "hidden";
      return;
    }

    overlay.style.visibility = "visible";
    overlay.style.transform = `translate(${rect.left + borderLeft}px, ${rect.top + borderTop}px)`;
    overlay.style.width = `${width}px`;
    overlay.style.height = `${height}px`;
  }, [containerRef]);

  useEffect(() => {
    if (typeof document === "undefined" || typeof window === "undefined") {
      return;
    }

    if (!shouldShowOverlay) {
      if (overlayRef.current) {
        overlayRef.current.style.display = "none";
      }
      return;
    }

    const target = containerRef.current;
    if (!target) {
      return;
    }

    let overlay = overlayRef.current;
    if (!overlay) {
      overlay = document.createElement("div");
      overlay.dataset.persistentIframeOverlay = persistKey;
      overlay.style.position = "fixed";
      overlay.style.top = "0";
      overlay.style.left = "0";
      overlay.style.pointerEvents = "none";
      overlay.style.zIndex = "var(--z-overlay)";
      overlay.style.visibility = "hidden";
      overlayRef.current = overlay;
      document.body.appendChild(overlay);
      forceRender((value) => value + 1);
    }

    overlay.dataset.persistentIframeOverlay = persistKey;
    overlay.style.display = "block";

    syncOverlayPosition();

    const resizeObserver =
      typeof ResizeObserver !== "undefined"
        ? new ResizeObserver(() => {
            syncOverlayPosition();
          })
        : null;
    resizeObserver?.observe(target);

    const scrollParents = getScrollableParents(target);
    const handleReposition = () => {
      syncOverlayPosition();
    };

    scrollParents.forEach((parent) =>
      parent.addEventListener("scroll", handleReposition, { passive: true })
    );
    window.addEventListener("resize", handleReposition);

    return () => {
      resizeObserver?.disconnect();
      scrollParents.forEach((parent) =>
        parent.removeEventListener("scroll", handleReposition)
      );
      window.removeEventListener("resize", handleReposition);
      if (overlay) {
        overlay.style.display = "none";
      }
    };
  }, [containerRef, persistKey, shouldShowOverlay, syncOverlayPosition]);

  useEffect(() => {
    return () => {
      clearLoadTimeout();
      if (overlayRef.current) {
        overlayRef.current.remove();
        overlayRef.current = null;
      }
    };
  }, [clearLoadTimeout]);

  const overlayElement = overlayRef.current;
  const overlayContent = showErrorOverlay
    ? {
        node: errorFallback,
        className: cn(
          "pointer-events-none flex h-full w-full items-center justify-center bg-neutral-50/90 dark:bg-neutral-950/90",
          errorClassName
        ),
      }
    : showLoadingOverlay
      ? {
          node: loadingFallback,
          className: cn(
            "pointer-events-none flex h-full w-full items-center justify-center bg-neutral-50 dark:bg-neutral-950",
            loadingClassName
          ),
        }
      : null;

  return (
    <>
      <div
        ref={containerRef}
        className={cn("relative", className)}
        style={style}
      />
      {overlayElement && overlayContent && shouldShowOverlay
        ? createPortal(
            <div className={overlayContent.className}>
              <div className="pointer-events-auto flex flex-col items-center gap-3 text-center">
                {overlayContent.node}
                {resumeMessage ? (
                  <p className="text-sm text-neutral-600 dark:text-neutral-300">
                    {resumeMessage}
                  </p>
                ) : null}
              </div>
            </div>,
            overlayElement
          )
        : null}
    </>
  );
}
