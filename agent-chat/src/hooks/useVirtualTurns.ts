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

export function scrollCompensationDelta(index: number, anchorIndex: number, previousHeight: number | undefined, nextHeight: number, estimate: number): number {
  return index < anchorIndex ? nextHeight - (previousHeight ?? estimate) : 0;
}

type VirtualRowMeasureNode = Pick<HTMLDivElement, "getBoundingClientRect" | "querySelector">;

export interface VirtualRowMeasurementState {
  heights: Map<number, number>;
  measured: { current: { total: number; count: number } };
  estimate: { current: number };
  anchorIndex: { current: number };
  scrollRef: { current: HTMLElement | null };
  bumpVersion: () => void;
}

export function measureVirtualRow(index: number, node: VirtualRowMeasureNode, state: VirtualRowMeasurementState): boolean {
  const next = node.getBoundingClientRect().height;
  const prev = state.heights.get(index);
  if (Math.abs((prev ?? state.estimate.current) - next) <= 1) return false;

  const delta = scrollCompensationDelta(index, state.anchorIndex.current, prev, next, state.estimate.current);
  state.heights.set(index, next);
  const measured = state.measured.current;
  if (prev == null) {
    measured.count += 1;
    measured.total += next;
  } else {
    measured.total += next - prev;
  }
  if (measured.count) state.estimate.current = Math.max(80, measured.total / measured.count);
  const scroll = state.scrollRef.current;
  if (scroll && delta) scroll.scrollTop += delta;
  state.bumpVersion();
  return true;
}

export function measureVirtualRowFromResize(index: number, node: VirtualRowMeasureNode, state: VirtualRowMeasurementState): boolean {
  if (node.querySelector('[data-disclosure-animating="true"]')) return false;
  return measureVirtualRow(index, node, state);
}

export function useVirtualTurns(count: number, enabled = true) {
  const rootRef = useRef<HTMLDivElement>(null);
  const scrollRef = useRef<HTMLElement | null>(null);
  const heights = useRef(new Map<number, number>());
  const observers = useRef(new Map<number, ResizeObserver>());
  const cleanups = useRef(new Map<number, () => void>());
  const measureCallbacks = useRef(new Map<number, (node: HTMLDivElement | null) => void>());
  const measureCacheKey = useRef({ count, enabled });
  const estimate = useRef(260);
  const measured = useRef({ total: 0, count: 0 });
  const anchorIndex = useRef(0);
  const [version, setVersion] = useState(0);
  const [viewport, setViewport] = useState({ top: 0, height: 900 });
  useLayoutEffect(() => {
    if (measureCacheKey.current.count === count && measureCacheKey.current.enabled === enabled) return;
    for (const obs of observers.current.values()) obs.disconnect();
    for (const cleanup of cleanups.current.values()) cleanup();
    observers.current.clear();
    cleanups.current.clear();
    measureCallbacks.current.clear();
    heights.current.clear();
    estimate.current = 260;
    measured.current = { total: 0, count: 0 };
    measureCacheKey.current = { count, enabled };
    setVersion((v) => v + 1);
  }, [count, enabled]);
  useLayoutEffect(() => {
    if (!enabled) return;
    const root = rootRef.current;
    const scroll = root?.closest<HTMLElement>("#messages, .gallery-transcript");
    if (!scroll) return;
    scrollRef.current = scroll;
    const update = () => setViewport({ top: scroll.scrollTop, height: scroll.clientHeight || 900 });
    update();
    scroll.addEventListener("scroll", update, { passive: true });
    const resize = new ResizeObserver(update);
    resize.observe(scroll);
    return () => {
      if (scrollRef.current === scroll) scrollRef.current = null;
      scroll.removeEventListener("scroll", update);
      resize.disconnect();
    };
  }, [enabled]);
  useLayoutEffect(() => () => {
    for (const obs of observers.current.values()) obs.disconnect();
    for (const cleanup of cleanups.current.values()) cleanup();
    observers.current.clear();
    cleanups.current.clear();
    measureCallbacks.current.clear();
  }, []);
  const range = useMemo(
    () => enabled ? virtualRange(count, heights.current, viewport.top, viewport.height, estimate.current) : { start: 0, end: count - 1, top: 0, bottom: 0, total: 0 },
    [count, enabled, version, viewport.height, viewport.top],
  );
  useLayoutEffect(() => {
    anchorIndex.current = range.start;
  }, [range.start]);
  const measure = (index: number) => {
    const cached = measureCallbacks.current.get(index);
    if (cached) return cached;
    const cb = (node: HTMLDivElement | null) => {
      observers.current.get(index)?.disconnect();
      observers.current.delete(index);
      cleanups.current.get(index)?.();
      cleanups.current.delete(index);
      if (!node || !enabled) return;
      const measurementState: VirtualRowMeasurementState = {
        heights: heights.current,
        measured,
        estimate,
        anchorIndex,
        scrollRef,
        bumpVersion: () => setVersion((v) => v + 1),
      };
      const updateFromResize = () => measureVirtualRowFromResize(index, node, measurementState);
      const updateFromExplicitRemeasure = () => measureVirtualRow(index, node, measurementState);
      updateFromResize();
      const obs = new ResizeObserver(updateFromResize);
      obs.observe(node);
      observers.current.set(index, obs);
      node.addEventListener("virtual-row-remeasure", updateFromExplicitRemeasure);
      cleanups.current.set(index, () => {
        obs.disconnect();
        node.removeEventListener("virtual-row-remeasure", updateFromExplicitRemeasure);
      });
    };
    measureCallbacks.current.set(index, cb);
    return cb;
  };
  return { rootRef: rootRef as RefObject<HTMLDivElement>, range, measure };
}
