import clsx from "clsx";
import { storage } from "@/lib/storage";
import React, {
  useCallback,
  useEffect,
  useRef,
  useState,
  type CSSProperties,
} from "react";

interface ResizableColumnsProps {
  left: React.ReactNode;
  right: React.ReactNode;
  storageKey?: string;
  defaultLeftWidth?: number; // px
  minLeft?: number; // px
  maxLeft?: number; // px
  separatorWidth?: number; // px
  className?: string;
  separatorClassName?: string;
}

export function ResizableColumns({
  left,
  right,
  storageKey = "resizableColumnsWidth",
  defaultLeftWidth = 360,
  minLeft = 240,
  maxLeft = 700,
  separatorWidth = 6,
  className,
  separatorClassName,
}: ResizableColumnsProps) {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const containerLeftRef = useRef<number>(0);
  const rafIdRef = useRef<number | null>(null);
  const [isResizing, setIsResizing] = useState(false);
  const [leftWidth, setLeftWidth] = useState<number>(() => {
    const stored = storageKey ? storage.getItem(storageKey) : null;
    const parsed = stored ? Number.parseInt(stored, 10) : defaultLeftWidth;
    if (Number.isNaN(parsed)) return defaultLeftWidth;
    return Math.min(Math.max(parsed, minLeft), maxLeft);
  });

  useEffect(() => {
    if (storageKey) storage.setItem(storageKey, String(leftWidth));
  }, [leftWidth, storageKey]);

  const onMouseMove = useCallback(
    (e: MouseEvent) => {
      if (rafIdRef.current != null) return;
      rafIdRef.current = window.requestAnimationFrame(() => {
        rafIdRef.current = null;
        const containerLeft = containerLeftRef.current;
        const clientX = e.clientX;
        const newWidth = Math.min(
          Math.max(clientX - containerLeft, minLeft),
          maxLeft
        );
        setLeftWidth(newWidth);
      });
    },
    [maxLeft, minLeft]
  );

  const stopResizing = useCallback(() => {
    setIsResizing(false);
    document.body.style.cursor = "";
    document.body.classList.remove("select-none");
    if (rafIdRef.current != null) {
      cancelAnimationFrame(rafIdRef.current);
      rafIdRef.current = null;
    }
    // Restore iframe pointer events
    const iframes = Array.from(document.querySelectorAll("iframe"));
    for (const el of iframes) {
      if (el instanceof HTMLIFrameElement) {
        const prev = el.dataset.prevPointerEvents;
        if (prev !== undefined) {
          if (prev === "__unset__") el.style.removeProperty("pointer-events");
          else el.style.pointerEvents = prev;
          delete el.dataset.prevPointerEvents;
        } else {
          el.style.removeProperty("pointer-events");
        }
      }
    }
    window.removeEventListener("mousemove", onMouseMove);
    window.removeEventListener("mouseup", stopResizing);
  }, [onMouseMove]);

  const startResizing = useCallback(
    (e: React.MouseEvent<HTMLDivElement>) => {
      e.preventDefault();
      setIsResizing(true);
      document.body.style.cursor = "col-resize";
      document.body.classList.add("select-none");
      if (containerRef.current) {
        const rect = containerRef.current.getBoundingClientRect();
        containerLeftRef.current = rect.left;
      }
      // Disable pointer events on iframes while dragging
      const iframes = Array.from(document.querySelectorAll("iframe"));
      for (const el of iframes) {
        if (el instanceof HTMLIFrameElement) {
          const current = el.style.pointerEvents;
          el.dataset.prevPointerEvents = current ? current : "__unset__";
          el.style.pointerEvents = "none";
        }
      }
      window.addEventListener("mousemove", onMouseMove);
      window.addEventListener("mouseup", stopResizing);
    },
    [onMouseMove, stopResizing]
  );

  useEffect(() => {
    return () => {
      window.removeEventListener("mousemove", onMouseMove);
      window.removeEventListener("mouseup", stopResizing);
    };
  }, [onMouseMove, stopResizing]);

  return (
    <div ref={containerRef} className={clsx(`flex h-full relative`, className)}>
      <div
        className="shrink-0 h-full"
        style={
          {
            width: `${leftWidth}px`,
            minWidth: `${leftWidth}px`,
            maxWidth: `${leftWidth}px`,
            userSelect: isResizing ? ("none" as const) : undefined,
          } as CSSProperties
        }
      >
        {left}
      </div>
      <div className="h-full block bg-neutral-200 dark:bg-neutral-800 w-[1px]"></div>
      <div className="flex-1 h-full">{right}</div>
      <div
        role="separator"
        aria-orientation="vertical"
        onMouseDown={startResizing}
        className={clsx(
          "absolute inset-y-0 cursor-col-resize bg-transparent hover:bg-neutral-200 dark:hover:bg-neutral-800 active:bg-neutral-300 dark:active:bg-neutral-800",
          separatorClassName
        )}
        style={{
          width: `${separatorWidth}px`,
          minWidth: `${separatorWidth}px`,
          transform: `translateX(calc(${leftWidth}px - 50%))`,
          zIndex: "var(--z-sidebar-resize-handle)",
        }}
        title="Resize"
      />
    </div>
  );
}

export default ResizableColumns;
