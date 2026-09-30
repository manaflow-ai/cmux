import assert from "node:assert/strict";
import { createElement } from "react";
import { act, create, type ReactTestRenderer } from "react-test-renderer";

const keys = ["window", "document", "location", "history", "sessionStorage", "WebSocket", "setTimeout", "clearTimeout", "IS_REACT_ACT_ENVIRONMENT"];
const descriptors = new Map(keys.map((key) => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
const timers = new Map<number, { run: () => void; delay: number }>();
const drafts = new Map<string, string>();
let nextTimer = 1;
const location = { pathname: "/", protocol: "http:", host: "fixture", search: "" };
const sockets: FakeSocket[] = [];
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
  receive(message: unknown) { this.onmessage?.({ data: JSON.stringify(message) } as MessageEvent); }
  close() { this.readyState = 3; this.onclose?.(); }
}
const setTimer = (run: () => void, delay: number) => { const id = nextTimer++; timers.set(id, { run, delay }); return id; };
const clearTimer = (id: number) => { timers.delete(id); };
for (const [key, value] of Object.entries({
  window: { setTimeout: setTimer, clearTimeout: clearTimer }, setTimeout: setTimer, clearTimeout: clearTimer,
  document: { title: "cmux agent" }, location,
  history: { replaceState(_state: unknown, _unused: string, path: string) { location.pathname = path; } },
  sessionStorage: { setItem(key: string, value: string) { drafts.set(key, value); } },
  WebSocket: FakeSocket, IS_REACT_ACT_ENVIRONMENT: true,
})) Object.defineProperty(globalThis, key, { configurable: true, writable: true, value });

let renderer: ReactTestRenderer | undefined;
try {
  const { useSession, composerDraftKey } = await import("../src/session");
  let state: ReturnType<typeof useSession>;
  function Harness() { state = useSession(); return null; }
  const update = async (callback: () => void) => { await act(async () => { callback(); }); };
  await act(async () => { renderer = create(createElement(Harness)); });
  const ws = sockets.at(-1)!;
  await update(() => ws.open());
  await update(() => { assert.equal(state.start({ provider: "fixture", cwd: "/fixture", prompt: "initial prompt" }), true); });
  const start = ws.sent.at(-1);
  await update(() => { state.reply("queued follow-up"); state.reply("second follow-up"); });
  await update(() => state.stop());
  assert.deepEqual(ws.sent.at(-1), { op: "stop", requestId: start.requestId }, "Stop must reach a startup before the client knows its session ID");
  assert.equal(state.phase, "composer");
  assert.equal(state.session, null);
  assert.equal(state.lastError, "");
  assert.equal(timers.size, 0);
  assert.equal(drafts.get(composerDraftKey), "initial prompt\n\nqueued follow-up\n\nsecond follow-up");
  const lateSession = { id: "late-session", provider: "fixture", cwd: "/fixture", status: "running", title: "late" };
  await update(() => {
    ws.receive({ kind: "session-created", requestId: start.requestId, session: lateSession });
    ws.receive({ kind: "history", sessionId: lateSession.id, session: lateSession, events: [] });
    ws.receive({ kind: "error", op: "start", requestId: start.requestId, message: "cancelled" });
    ws.receive({ kind: "start-stopped", requestId: start.requestId });
  });
  assert.equal(state.phase, "composer", "late replies must not reopen a canceled startup");
  assert.equal(state.lastError, "");
  assert.ok(!ws.sent.some((message) => message.op === "send"));

  await update(() => { state.start({ provider: "fixture", cwd: "/fixture", prompt: "stop while offline" }); });
  const offlineStart = ws.sent.at(-1);
  await update(() => ws.close());
  await update(() => state.stop());
  assert.equal(state.phase, "composer");
  assert.equal(drafts.get(composerDraftKey), "stop while offline");
  const [retryId, retry] = [...timers].find(([, timer]) => timer.delay === 800)!;
  timers.delete(retryId);
  await update(retry.run);
  const replacement = sockets.at(-1)!;
  await update(() => replacement.open());
  assert.deepEqual(replacement.sent, [{ op: "stop", requestId: offlineStart.requestId }], "reconnect must retry cancellation instead of resending the canceled prompt");
  await update(() => replacement.receive({ kind: "start-stopped", requestId: offlineStart.requestId }));

  await update(() => { state.start({ provider: "fixture", cwd: "/fixture", prompt: "new startup" }); });
  const nextStart = replacement.sent.at(-1);
  await update(() => replacement.receive({ kind: "start-stopped", requestId: offlineStart.requestId }));
  assert.equal(state.session?.id, `pending-${nextStart.requestId}`, "an old stop acknowledgement must not cancel a newer startup");
  const current = { ...lateSession, id: "current-session", title: "current", status: "idle" };
  await update(() => replacement.receive({ kind: "session-created", requestId: nextStart.requestId, session: current }));
  await update(() => state.stop());
  assert.deepEqual(replacement.sent.at(-1), { op: "stop", sessionId: current.id }, "known sessions retain the normal Stop path");
  await update(() => replacement.close());
  const [nextRetryId, nextRetry] = [...timers].find(([, timer]) => timer.delay === 800)!;
  timers.delete(nextRetryId);
  await update(nextRetry.run);
  const recovered = sockets.at(-1)!;
  await update(() => recovered.open());
  assert.deepEqual(recovered.sent, [{ op: "subscribe", sessionId: current.id }], "acknowledged cancellations must leave no retry behind");
  console.log("Stop before startup acknowledgement, draft recovery, late replies, offline cancellation, and newer starts: OK");
} finally {
  if (renderer) await act(async () => { renderer!.unmount(); });
  for (const [key, descriptor] of descriptors) {
    if (descriptor) Object.defineProperty(globalThis, key, descriptor);
    else delete (globalThis as any)[key];
  }
  assert.equal(timers.size, 0);
}
