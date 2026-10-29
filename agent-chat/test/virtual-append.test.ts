import assert from "node:assert/strict";
import { createElement } from "react";
import { act, create, type ReactTestRenderer } from "react-test-renderer";
import { useVirtualTurns } from "../src/hooks/useVirtualTurns";

const globalKeys = ["ResizeObserver", "IS_REACT_ACT_ENVIRONMENT"];
const descriptors = new Map(globalKeys.map((key) => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
class Node extends EventTarget {
  height = 100;
  scrollTop = 0;
  clientHeight = 300;
  listeners = new Map<string, number>();
  closest() { return scroll; }
  getBoundingClientRect() { return { height: this.height }; }
  querySelector() { return null; }
  override addEventListener(type: string, callback: EventListenerOrEventListenerObject | null, options?: AddEventListenerOptions | boolean) {
    super.addEventListener(type, callback, options);
    this.listeners.set(type, (this.listeners.get(type) ?? 0) + 1);
  }
  override removeEventListener(type: string, callback: EventListenerOrEventListenerObject | null, options?: EventListenerOptions | boolean) {
    super.removeEventListener(type, callback, options);
    this.listeners.set(type, (this.listeners.get(type) ?? 0) - 1);
  }
}
const scroll = new Node();
const root = new Node();
const rows = new Map([0, 24, 25, 29].map((index) => [index, new Node()]));
class Observer {
  static all: Observer[] = [];
  targets = new Set<Node>();
  disconnects = 0;
  constructor(readonly callback: () => void) { Observer.all.push(this); }
  observe(node: Node) { this.targets.add(node); }
  disconnect() { this.disconnects++; this.targets.clear(); }
}
Object.defineProperty(globalThis, "ResizeObserver", { configurable: true, writable: true, value: Observer });
Object.defineProperty(globalThis, "IS_REACT_ACT_ENVIRONMENT", { configurable: true, writable: true, value: true });

let renderer: ReactTestRenderer | undefined;
try {
  let virtual: ReturnType<typeof useVirtualTurns>;
  const appendedRanges: { top: number; firstVisible: number }[] = [];
  function Harness({ count, enabled = true }: { count: number; enabled?: boolean }) {
    virtual = useVirtualTurns(count, enabled);
    if (count === 31) appendedRanges.push({ top: virtual.range.top, firstVisible: virtual.range.firstVisible });
    return createElement("div", { ref: virtual.rootRef, fixture: "root" },
      [...rows.keys()].filter((index) => index < count).map((index) => createElement("div", {
        key: index, ref: virtual.measure(index), fixture: index,
      })));
  }
  const update = async (callback: () => void) => { await act(async () => { callback(); }); };
  await act(async () => {
    renderer = create(createElement(Harness, { count: 30 }), {
      createNodeMock: (element) => {
        const { fixture } = element.props as { fixture: string | number };
        return fixture === "root" ? root : rows.get(fixture as number);
      },
    });
  });
  await update(() => { scroll.scrollTop = 1050; scroll.dispatchEvent(new Event("scroll")); });
  assert.equal(virtual.range.top, 700);
  assert.equal(virtual.range.total, 3000);
  const range = virtual.range;
  const rowCallback = virtual.measure(29);
  const initialObservers = Observer.all.length;
  const rowObserver = Observer.all.find((observer) => observer.targets.has(rows.get(29)!))!;
  assert.ok(rowObserver);

  await update(() => renderer!.update(createElement(Harness, { count: 31 })));
  assert.ok(appendedRanges.every((entry) => entry.top === range.top && entry.firstVisible === range.firstVisible),
    "append must preserve the row and top spacer throughout the layout update");
  assert.equal(virtual.range.top, range.top, "appending a turn must preserve the measured top spacer");
  assert.equal(virtual.range.firstVisible, range.firstVisible, "appending a turn must preserve the row being read");
  assert.equal(virtual.range.total, 3100, "the new turn uses the learned estimate");
  assert.equal(Observer.all.length, initialObservers, "append must not recreate mounted row observers");
  assert.equal(virtual.measure(29), rowCallback, "existing row refs remain stable across append");
  assert.equal(rowObserver.disconnects, 0);
  assert.equal(scroll.scrollTop, 1050);
  console.log(`virtual append fixture: top spacer ${range.top} -> ${virtual.range.top}, no recreated row observers`);

  // A retained observer must use the new count: after append, row 29 is now
  // above an anchor in row 30 and its growth needs scroll compensation.
  await update(() => { scroll.scrollTop = 3050; scroll.dispatchEvent(new Event("scroll")); });
  await update(() => { rows.get(29)!.height = 150; rowObserver.callback(); });
  assert.equal(scroll.scrollTop, 3100, "retained observers must compensate using the current turn count");
  await update(() => renderer!.update(createElement(Harness, { count: 32 })));
  assert.equal(virtual.measure(29), rowCallback);
  assert.equal(rowObserver.disconnects, 0);

  // Shrinking history and toggling virtualization still invalidate the cache
  // and remeasure the rows that remain mounted.
  await update(() => renderer!.update(createElement(Harness, { count: 20 })));
  assert.ok(rowObserver.disconnects > 0);
  assert.equal(virtual.range.total, 2000);
  assert.equal(rows.get(29)!.listeners.get("virtual-row-remeasure"), 0);
  await update(() => renderer!.update(createElement(Harness, { count: 20, enabled: false })));
  assert.equal(virtual.range.total, 0);
  assert.equal(scroll.listeners.get("scroll"), 0);
  await update(() => renderer!.update(createElement(Harness, { count: 30, enabled: true })));
  assert.equal(scroll.listeners.get("scroll"), 1);
  assert.ok(Observer.all.some((observer) => observer.targets.has(rows.get(29)!)));
  await act(async () => { renderer!.unmount(); });
  renderer = undefined;
  assert.ok(Observer.all.every((observer) => observer.targets.size === 0));
  assert.equal(scroll.listeners.get("scroll"), 0);
  for (const row of rows.values()) assert.equal(row.listeners.get("virtual-row-remeasure"), 0);
} finally {
  if (renderer) await act(async () => { renderer!.unmount(); });
  for (const [key, descriptor] of descriptors) {
    if (descriptor) Object.defineProperty(globalThis, key, descriptor);
    else delete (globalThis as any)[key];
  }
}
