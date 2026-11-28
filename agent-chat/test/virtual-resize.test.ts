import assert from "node:assert/strict";
import { createElement } from "react";
import { act, create, type ReactTestRenderer } from "react-test-renderer";

// react-test-renderer has its own scheduler, so adapt React DOM's flushSync to
// act() and verify that the hook commits its new range before the event returns.
const { mock } = await import("bun:test");
mock.module("react-dom", () => ({ flushSync: (callback: () => void) => { act(callback); } }));
const { useVirtualTurns, virtualRange } = await import("../src/hooks/useVirtualTurns");

const globalKeys = ["ResizeObserver", "IS_REACT_ACT_ENVIRONMENT"];
const descriptors = new Map(globalKeys.map((key) => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
class Scroll extends EventTarget {
  scrollTop = 0;
  clientHeight = 619;
  closest() { return this; }
}
class Observer {
  static all: Observer[] = [];
  constructor(readonly callback: ResizeObserverCallback) { Observer.all.push(this); }
  observe() {}
  disconnect() {}
  notify() { this.callback([], this as unknown as ResizeObserver); }
}

Object.defineProperty(globalThis, "ResizeObserver", { configurable: true, writable: true, value: Observer });
Object.defineProperty(globalThis, "IS_REACT_ACT_ENVIRONMENT", { configurable: true, writable: true, value: true });

const scroll = new Scroll();
const root = { closest: () => scroll };
let renderer: ReactTestRenderer | undefined;
let virtual!: ReturnType<typeof useVirtualTurns>;
function Harness() {
  virtual = useVirtualTurns(400);
  const { start, end } = virtual.range;
  return createElement("div", { ref: virtual.rootRef }, Array.from({ length: end - start + 1 }, (_, offset) => {
    const index = start + offset;
    return createElement("div", { key: index, "data-row": index });
  }));
}
const mountedRows = () => renderer!.root
  .findAll((node) => Number.isInteger(node.props["data-row"]))
  .map((node) => node.props["data-row"] as number);
const assertViewportMounted = (top: number, height: number) => {
  const expected = virtualRange(400, new Map(), top, height);
  assert.deepEqual(virtual.range, expected);
  assert.ok(mountedRows().includes(expected.firstVisible), `viewport row ${expected.firstVisible} must be mounted`);
};

try {
  scroll.scrollTop = 42149;
  await act(async () => {
    renderer = create(createElement(Harness), { createNodeMock: () => root });
  });
  assertViewportMounted(42149, 619);

  // A wheel burst moves the scroll position before React can schedule its next
  // render. The range must already cover the new viewport when dispatch returns.
  scroll.scrollTop = 43000;
  scroll.dispatchEvent(new Event("scroll"));
  assertViewportMounted(43000, 619);
  scroll.scrollTop = 45351;
  scroll.dispatchEvent(new Event("scroll"));
  assertViewportMounted(45351, 619);

  // Window resize notifications use the same synchronous path as scrolling.
  scroll.clientHeight = 691;
  Observer.all[0]!.notify();
  assertViewportMounted(45351, 691);
  console.log("virtual resize/scroll burst: viewport rows mounted synchronously");
} finally {
  if (renderer) await act(async () => { renderer!.unmount(); });
  for (const [key, descriptor] of descriptors) {
    if (descriptor) Object.defineProperty(globalThis, key, descriptor);
    else delete (globalThis as any)[key];
  }
}
