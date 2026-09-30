import assert from "node:assert/strict";
import { createElement } from "react";
import { act, create, type ReactTestRenderer } from "react-test-renderer";
import type { AgentEvent } from "../src/session";

const globals = ["window", "document", "location", "history", "sessionStorage", "WebSocket", "IS_REACT_ACT_ENVIRONMENT"];
const descriptors = new Map(globals.map((key) => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
const timers = new Map<number, { callback: () => void; delay: number }>();
let nextTimer = 1;
const sockets: FakeSocket[] = [];
const location = { pathname: "/s/stream-fixture", protocol: "http:", host: "fixture", search: "" };
class FakeSocket {
  static OPEN = 1;
  readyState = 0;
  onopen: (() => void) | null = null;
  onmessage: ((event: MessageEvent) => void) | null = null;
  onclose: (() => void) | null = null;
  sent: any[] = [];
  constructor(_url: string) { sockets.push(this); }
  send(data: string) { this.sent.push(JSON.parse(data)); }
  open() { this.readyState = FakeSocket.OPEN; this.onopen?.(); }
  close() { this.readyState = 3; this.onclose?.(); }
  receive(message: unknown) { this.onmessage?.({ data: JSON.stringify(message) } as MessageEvent); }
}
for (const [key, value] of Object.entries({
  window: {
    setTimeout(callback: () => void, delay: number) { const id = nextTimer++; timers.set(id, { callback, delay }); return id; },
    clearTimeout(id: number) { timers.delete(id); },
  },
  document: { title: "cmux agent" }, location,
  history: { replaceState(_state: unknown, _unused: string, path: string) { location.pathname = path; } },
  sessionStorage: { setItem() {} }, WebSocket: FakeSocket, IS_REACT_ACT_ENVIRONMENT: true,
})) Object.defineProperty(globalThis, key, { configurable: true, writable: true, value });

const originalSlice = Array.prototype.slice;
let copies = 0;
let renderer: ReactTestRenderer | undefined;
try {
  const { useSession } = await import("../src/session");
  let state: ReturnType<typeof useSession>;
  let renders = 0;
  function Harness() { renders++; state = useSession(); return null; }
  const update = async (callback: () => void) => { await act(async () => { callback(); }); };
  await act(async () => { renderer = create(createElement(Harness)); });
  let ws = sockets.at(-1)!;
  await update(() => ws.open());
  let sessionId = "stream-fixture";
  const receive = async (message: unknown) => update(() => ws.receive(message));
  const event = async (evt: AgentEvent) => receive({ kind: "event", sessionId, evt });
  const history = async (events: AgentEvent[]) => receive({ kind: "history", sessionId,
    session: { id: sessionId, provider: "fixture", cwd: "/fixture", title: "fixture", status: "running", mode: "transcript" }, events });
  const frameTimers = () => [...timers.entries()].filter(([, timer]) => timer.delay === 16);
  const flush = async () => {
    const frames = frameTimers();
    assert.equal(frames.length, 1, "one bounded stream update should be scheduled");
    await update(() => { timers.delete(frames[0]![0]); frames[0]![1].callback(); });
  };
  const seed: AgentEvent[] = [];
  for (let index = 0; index < 500; index++) seed.push(
    { kind: "user", text: `prompt ${index}` }, { kind: "assistant", text: `answer ${index}` }, { kind: "done" },
  );
  await history(seed);
  const before = state.blocks;
  before.forEach(Object.freeze);
  Object.freeze(before);
  const initialRenders = renders;
  Array.prototype.slice = function (...args: any[]) {
    if (this[0]?.kind === "user") copies++;
    return originalSlice.apply(this, args);
  } as typeof Array.prototype.slice;
  for (let index = 0; index < 32; index++) await event({ kind: "delta", text: "x" });
  assert.ok(copies <= 1, "a stream burst must not copy the transcript for every chunk");
  assert.equal(renders, initialRenders, "chunks should share one scheduled React update");
  await flush();
  assert.equal(copies, 1);
  assert.equal(renders, initialRenders + 1);
  assert.deepEqual(state.blocks.at(-1), { kind: "assistant", text: "x".repeat(32), open: true });
  assert.equal(before.length, 1500, "live batching must preserve prior state");
  Array.prototype.slice = originalSlice;
  console.log(`stream fixture: 32 chunks, 1500 prior blocks, ${copies} transcript copy, ${renders - initialRenders} React update`);

  await event({ kind: "delta", text: "a" });
  await event({ kind: "thinking", text: "thought " });
  await event({ kind: "thinking", text: "more" });
  await event({ kind: "tool-start", toolId: "tool", name: "Read" });
  assert.equal(frameTimers().length, 0, "tools must flush stream text immediately");
  assert.deepEqual(state.blocks.slice(-3), [
    { kind: "assistant", text: "x".repeat(32) + "a", open: false },
    { kind: "thinking", text: "thought more", open: false },
    { kind: "tool", toolId: "tool", name: "Read", detail: undefined, status: "running" },
  ]);
  await event({ kind: "delta", text: "approval context" });
  await receive({ kind: "session-attention", sessionId, attention: "needs input" });
  assert.equal(frameTimers().length, 0);
  assert.equal(state.session?.attention, "needs input");
  assert.equal((state.blocks.at(-1) as any).text, "approval context");
  await event({ kind: "delta", text: " ending" });
  await receive({ kind: "session-status", sessionId, status: "idle" });
  assert.equal((state.blocks.at(-1) as any).text, "approval context ending");
  await event({ kind: "done", stats: "done" });
  assert.equal(frameTimers().length, 0);
  assert.deepEqual(state.blocks.at(-1), { kind: "footer", text: "done" });

  await event({ kind: "delta", text: "replaced text" });
  const staleFrame = frameTimers()[0]![1].callback;
  await history([{ kind: "assistant", text: "authoritative history" }]);
  assert.equal(frameTimers().length, 0, "history replacement must cancel the old batch");
  await event({ kind: "delta", text: "new chunk" });
  const beforeStale = renders;
  await update(staleFrame);
  assert.equal(renders, beforeStale, "a queued old timer must not flush a newer batch");
  assert.equal(frameTimers().length, 1);
  await flush();
  assert.deepEqual(state.blocks.map((block: any) => block.text), ["authoritative history", "new chunk"]);
  await event({ kind: "delta", text: " before reply" });
  await update(() => state.reply("my reply"));
  assert.equal(frameTimers().length, 0);
  assert.deepEqual(state.blocks.slice(-2), [
    { kind: "assistant", text: "new chunk before reply", open: false }, { kind: "user", text: "my reply" },
  ], "optimistic replies must follow already-received stream text");

  await event({ kind: "delta", text: "abandoned text" });
  const abandonedFrame = frameTimers()[0]![1].callback;
  await update(() => state.compose());
  assert.equal(frameTimers().length, 0);
  await update(() => { assert.equal(state.start({ provider: "fixture", cwd: "/fixture", prompt: "new conversation" }), true); });
  await update(abandonedFrame);
  assert.deepEqual(state.blocks, [{ kind: "user", text: "new conversation" }]);
  sessionId = "second-session";
  await receive({ kind: "session-created", requestId: ws.sent.at(-1).requestId,
    session: { id: sessionId, provider: "fixture", cwd: "/fixture", title: "second", status: "running" } });
  await event({ kind: "delta", text: "received before disconnect" });
  await update(() => ws.close());
  assert.equal(frameTimers().length, 0);
  assert.equal((state.blocks.at(-1) as any).text, "received before disconnect");
  await act(async () => { renderer!.unmount(); });
  renderer = undefined;

  await act(async () => { renderer = create(createElement(Harness)); });
  ws = sockets.at(-1)!;
  sessionId = "stream-fixture";
  await update(() => ws.open());
  await event({ kind: "thinking", text: "pending during unmount" });
  const disposedFrame = frameTimers()[0]![1].callback;
  await act(async () => { renderer!.unmount(); });
  renderer = undefined;
  assert.equal(frameTimers().length, 0);
  const disposedRenders = renders;
  await update(disposedFrame);
  assert.equal(renders, disposedRenders);
  assert.equal(timers.size, 0, "all owned deadlines must be released");
} finally {
  Array.prototype.slice = originalSlice;
  if (renderer) await act(async () => { renderer!.unmount(); });
  for (const [key, descriptor] of descriptors) {
    if (descriptor) Object.defineProperty(globalThis, key, descriptor);
    else delete (globalThis as any)[key];
  }
}
