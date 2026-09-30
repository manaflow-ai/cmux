import assert from "node:assert/strict";
import { createElement } from "react";
import { act, create, type ReactTestRenderer } from "react-test-renderer";
import type { AgentEvent, Block } from "../src/session";

const globals = ["window", "document", "location", "WebSocket", "IS_REACT_ACT_ENVIRONMENT"];
const descriptors = new Map(globals.map((key) => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
let socket: FakeSocket;
class FakeSocket {
  static OPEN = 1;
  readyState = 0;
  onopen: (() => void) | null = null;
  onmessage: ((event: MessageEvent) => void) | null = null;
  onclose: (() => void) | null = null;
  constructor(_url: string) { socket = this; }
  send(_data: string) {}
  close() { this.readyState = 3; this.onclose?.(); }
}
for (const [key, value] of Object.entries({
  window: {}, document: { title: "cmux agent" },
  location: { pathname: "/s/history-fixture", protocol: "http:", host: "fixture" },
  WebSocket: FakeSocket, IS_REACT_ACT_ENVIRONMENT: true,
})) Object.defineProperty(globalThis, key, { configurable: true, writable: true, value });

const turns = 400;
const events: AgentEvent[] = [];
const expected: Block[] = [];
for (let index = 0; index < turns; index++) {
  const entries = [{ text: `step ${index}`, status: "pending" as const }];
  const files = [{ path: `file-${index}.ts`, status: "modified", adds: 1, dels: 0 }];
  events.push(
    { kind: "user", text: `prompt ${index}` },
    { kind: "thinking", text: `reason ${index}` },
    { kind: "plan", entries },
    { kind: "tool-start", toolId: `tool-${index}`, name: "Read", detail: `input ${index}` },
    { kind: "tool-end", toolId: `tool-${index}`, ok: true, detail: `output ${index}` },
    { kind: "files-changed", files },
    { kind: "delta", text: "partial" },
    { kind: "assistant", text: `answer ${index}` },
    { kind: "done", stats: `stats ${index}` },
  );
  expected.push(
    { kind: "user", text: `prompt ${index}` },
    { kind: "thinking", text: `reason ${index}`, open: false },
    { kind: "plan", entries },
    { kind: "tool", toolId: `tool-${index}`, name: "Read", detail: `input ${index}`, out: `output ${index}`, status: "ok" },
    { kind: "files", files, revision: String(index + 1) },
    { kind: "assistant", text: `answer ${index}`, open: false },
    { kind: "footer", text: `stats ${index}` },
  );
}

let renderer: ReactTestRenderer | undefined;
const originalIterator = Array.prototype[Symbol.iterator];
const originalMap = Array.prototype.map;
let visits = 0;
function record(array: any[]) {
  if (array[0]?.kind === "user") visits += array.length;
}
try {
  const { useSession, foldEvent, foldEvents } = await import("../src/session");
  let state: ReturnType<typeof useSession>;
  function Harness() { state = useSession(); return null; }
  await act(async () => { renderer = create(createElement(Harness)); });
  await act(async () => { socket.readyState = FakeSocket.OPEN; socket.onopen?.(); });
  // Count references traversed by transcript array iteration/map, rather than
  // relying on wall-clock thresholds that vary with runner load. The fixture
  // exercises the production history handler and checks the resulting blocks.
  Array.prototype[Symbol.iterator] = function () {
    record(this);
    return originalIterator.call(this);
  };
  Array.prototype.map = function (callback: any, thisArg?: any) {
    record(this);
    return originalMap.call(this, callback, thisArg);
  } as typeof Array.prototype.map;
  const startedAt = performance.now();
  await act(async () => {
    socket.onmessage?.({ data: JSON.stringify({
      kind: "history", sessionId: "history-fixture",
      session: { id: "history-fixture", provider: "fixture", title: "history", cwd: "/fixture", status: "idle" }, events,
    }) } as MessageEvent);
  });
  const elapsed = performance.now() - startedAt;
  Array.prototype[Symbol.iterator] = originalIterator;
  Array.prototype.map = originalMap;
  assert.deepEqual(state.blocks, expected, "history replay must preserve all displayed blocks and file revisions");
  console.log(`history fixture: ${events.length} events, ${state.blocks.length} blocks, ${visits} array references traversed, ${elapsed.toFixed(1)}ms`);
  assert.ok(visits <= events.length * 8, "history replay must not repeatedly copy or scan its growing transcript prefix");

  const seed: Block[] = [
    { kind: "tool", toolId: "reused", name: "Read", status: "running" },
    { kind: "files", files: [], revision: "1" },
    { kind: "user", text: "seed" },
    { kind: "plan", entries: [{ text: "old plan", status: "pending" }] },
    { kind: "assistant", text: "prefix", open: true },
  ];
  const seedSnapshot = JSON.stringify(seed);
  seed.forEach(Object.freeze);
  Object.freeze(seed);
  const update: AgentEvent[] = [
    { kind: "tool-end", toolId: "reused", ok: false, detail: "first failure" },
    { kind: "tool-start", toolId: "reused", name: "Bash", detail: "input" },
    { kind: "tool-end", toolId: "reused", ok: true, detail: "final output" },
    { kind: "plan", entries: [{ text: "updated plan", status: "in_progress" }] },
    { kind: "delta", text: "hi" }, { kind: "delta", text: " there" },
    { kind: "thinking", text: "reason" },
    { kind: "assistant", text: "final" }, { kind: "done", stats: "done" },
    { kind: "user", text: "next turn" },
    { kind: "plan", entries: [{ text: "next plan", status: "pending" }] },
    { kind: "files-changed", files: [] }, { kind: "files-changed", files: [] },
    { kind: "status", text: "status" }, { kind: "error", message: "error" },
  ];
  const folded = foldEvents(seed, update);
  assert.deepEqual(folded, [
    { kind: "tool", toolId: "reused", name: "Read", status: "ok", out: "final output" },
    { kind: "files", files: [], revision: "1" }, { kind: "user", text: "seed" },
    { kind: "plan", entries: [{ text: "updated plan", status: "in_progress" }] },
    { kind: "assistant", text: "prefix", open: false },
    { kind: "tool", toolId: "reused", name: "Bash", detail: "input", status: "ok", out: "final output" },
    { kind: "assistant", text: "hi there", open: false },
    { kind: "thinking", text: "reason", open: false },
    { kind: "assistant", text: "final", open: false }, { kind: "footer", text: "done" },
    { kind: "user", text: "next turn" },
    { kind: "plan", entries: [{ text: "next plan", status: "pending" }] },
    { kind: "files", files: [], revision: "2" }, { kind: "files", files: [], revision: "3" },
    { kind: "status", text: "status" }, { kind: "error", text: "error" },
  ]);
  assert.deepEqual(update.reduce(foldEvent, seed), folded, "live and batch folding must share the same displayed behavior");
  assert.equal(JSON.stringify(seed), seedSnapshot, "neither replay nor live folding may mutate prior state");
  assert.equal(foldEvents(seed, []), seed);
  assert.equal(foldEvents(seed, [{ kind: "meta", model: "ignored" }]), seed);
} finally {
  Array.prototype[Symbol.iterator] = originalIterator;
  Array.prototype.map = originalMap;
  if (renderer) await act(async () => { renderer!.unmount(); });
  for (const [key, descriptor] of descriptors) {
    if (descriptor) Object.defineProperty(globalThis, key, descriptor);
    else delete (globalThis as any)[key];
  }
}
