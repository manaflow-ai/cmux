import { useLayoutEffect, useMemo, useRef, useState, type RefObject } from "react";

export interface VirtualRange {
  start: number;
  end: number;
  top: number;
  bottom: number;
  total: number;
}

export function virtualRange(count: number, heights: Map<number, number>, scrollTop: number, viewport: number, estimate = 260, overscan = 3): VirtualRange {
  const offsets = new Array<number>(count + 1);
  offsets[0] = 0;
  for (let i = 0; i < count; i++) offsets[i + 1] = offsets[i] + (heights.get(i) ?? estimate);
  const total = offsets[count] ?? 0;
  let start = 0;
  while (start < count && offsets[start + 1] < scrollTop) start++;
  let end = start;
  const limit = scrollTop + viewport;
  while (end < count && offsets[end] < limit) end++;
  start = Math.max(0, start - overscan);
  end = Math.min(count - 1, end + overscan);
  return {
    start,
    end,
    top: offsets[start] ?? 0,
    bottom: Math.max(0, total - (offsets[end + 1] ?? total)),
    total,
  };
}

export function useVirtualTurns(count: number, enabled = true) {
  const rootRef = useRef<HTMLDivElement>(null);
  const heights = useRef(new Map<number, number>());
  const observers = useRef(new Map<number, ResizeObserver>());
  const measureCallbacks = useRef(new Map<number, (node: HTMLDivElement | null) => void>());
  const measureCacheKey = useRef({ count, enabled });
  const [version, setVersion] = useState(0);
  const [viewport, setViewport] = useState({ top: 0, height: 900 });
  useLayoutEffect(() => {
    if (measureCacheKey.current.count === count && measureCacheKey.current.enabled === enabled) return;
    for (const obs of observers.current.values()) obs.disconnect();
    observers.current.clear();
    measureCallbacks.current.clear();
    heights.current.clear();
    measureCacheKey.current = { count, enabled };
    setVersion((v) => v + 1);
  }, [count, enabled]);
  useLayoutEffect(() => {
    if (!enabled) return;
    const root = rootRef.current;
    const scroll = root?.closest<HTMLElement>("#messages, .gallery-transcript");
    if (!scroll) return;
    const update = () => setViewport({ top: scroll.scrollTop, height: scroll.clientHeight || 900 });
    update();
    scroll.addEventListener("scroll", update, { passive: true });
    const resize = new ResizeObserver(update);
    resize.observe(scroll);
    return () => {
      scroll.removeEventListener("scroll", update);
      resize.disconnect();
    };
  }, [enabled]);
  useLayoutEffect(() => () => {
    for (const obs of observers.current.values()) obs.disconnect();
    observers.current.clear();
    measureCallbacks.current.clear();
  }, []);
  const range = useMemo(
    () => enabled ? virtualRange(count, heights.current, viewport.top, viewport.height) : { start: 0, end: count - 1, top: 0, bottom: 0, total: 0 },
    [count, enabled, version, viewport.height, viewport.top],
  );
  const measure = (index: number) => {
    const cached = measureCallbacks.current.get(index);
    if (cached) return cached;
    const cb = (node: HTMLDivElement | null) => {
      observers.current.get(index)?.disconnect();
      observers.current.delete(index);
      if (!node || !enabled) return;
      const update = () => {
        const next = node.getBoundingClientRect().height;
        if (Math.abs((heights.current.get(index) ?? 0) - next) > 1) {
          heights.current.set(index, next);
          setVersion((v) => v + 1);
        }
      };
      update();
      const obs = new ResizeObserver(update);
      obs.observe(node);
      observers.current.set(index, obs);
    };
    measureCallbacks.current.set(index, cb);
    return cb;
  };
  return { rootRef: rootRef as RefObject<HTMLDivElement>, range, measure };
}
