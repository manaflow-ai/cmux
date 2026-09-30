import assert from "node:assert/strict";
import { createElement } from "react";
import { act, create, type ReactTestRenderer } from "react-test-renderer";

const globals = ["window", "document", "location", "history", "sessionStorage", "WebSocket", "IS_REACT_ACT_ENVIRONMENT"];
const descriptors = new Map(globals.map((key) => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
const timers = new Map<number, () => void>();
let nextTimer = 1;
const location = { pathname: "/", protocol: "http:", host: "fixture", search: "" };
const sockets: FakeSocket[] = [];
const popups: { closed: boolean; location: { href: string }; focuses: number; close(): void; focus(): void }[] = [];
const navigations: string[] = [];
let blocked = false;
let nextSocket: ((ws: FakeSocket) => void) | undefined;
let reconnectTimer: ReturnType<typeof setTimeout> | undefined;
function replacementSocket(): Promise<FakeSocket> {
  return new Promise((resolve, reject) => {
    reconnectTimer = setTimeout(() => reject(new Error("session connection did not retry")), 2_500);
    nextSocket = (ws) => { clearTimeout(reconnectTimer); resolve(ws); };
  });
}
class FakeSocket {
  static OPEN = 1;
  readyState = 0;
  onopen: (() => void) | null = null;
  onmessage: ((event: MessageEvent) => void) | null = null;
  onclose: (() => void) | null = null;
  sent: any[] = [];
  constructor(_url: string) { sockets.push(this); nextSocket?.(this); nextSocket = undefined; }
  send(data: string) { this.sent.push(JSON.parse(data)); }
  open() { this.readyState = FakeSocket.OPEN; this.onopen?.(); }
  receive(message: unknown) { this.onmessage?.({ data: JSON.stringify(message) } as MessageEvent); }
  close() { this.readyState = 3; this.onclose?.(); }
}
const fixtures: Record<string, unknown> = {
  window: {
    setTimeout(callback: () => void, _delay: number) { const id = nextTimer++; timers.set(id, callback); return id; },
    clearTimeout(id: number) { timers.delete(id); },
    open(url: string) {
      if (blocked) return null;
      const popup = { closed: false, location: { href: url }, focuses: 0,
        close() { this.closed = true; }, focus() { this.focuses++; } };
      popups.push(popup);
      return popup;
    },
    location: { assign(url: string) { navigations.push(url); } },
  },
  document: { title: "cmux agent" }, location,
  history: { replaceState(_state: unknown, _unused: string, path: string) { location.pathname = path; } },
  sessionStorage: { setItem() {} }, WebSocket: FakeSocket, IS_REACT_ACT_ENVIRONMENT: true,
};
for (const [key, value] of Object.entries(fixtures)) Object.defineProperty(globalThis, key, { configurable: true, writable: true, value });

let renderer: ReactTestRenderer | undefined;
try {
  const { useSession } = await import("../src/session");
  let state: ReturnType<typeof useSession>;
  function Harness() { state = useSession(); return null; }
  await act(async () => { renderer = create(createElement(Harness)); });
  let ws = sockets[0]!;
  const update = async (action: () => void) => { await act(async () => { action(); }); };
  const receive = async (message: unknown) => update(() => ws.receive(message));
  await update(() => ws.open());
  const startSession = async (id: string) => {
    await update(() => { assert.equal(state.start({ provider: "fixture", cwd: "/fixture", prompt: id }), true); });
    const session = { id, provider: "fixture", cwd: "/fixture", title: id, status: "idle", createdAt: 1 };
    await receive({ kind: "session-created", requestId: ws.sent.at(-1).requestId, session });
    await receive({ kind: "history", sessionId: id, session, events: [] });
  };
  const child = (id: string, parentSessionId: string) => ({ id, parentSessionId, provider: "fixture", cwd: "/fixture", title: id, status: "idle" });
  await startSession("old-session");
  await update(() => state.fork());
  assert.equal(state.forkPending, true);
  await update(() => state.compose());
  assert.equal(state.forkPending, false, "leaving a chat must clear its pending fork action");
  assert.equal(popups.length, 1, "fork must reserve a popup during the click");
  assert.equal(popups[0]!.closed, true, "leaving must close the reserved fork tab");
  await receive({ kind: "session-forked", session: child("late-child", "old-session") });
  assert.equal(popups.length, 1, "a late fork reply must not open a tab after leaving");

  await startSession("current-session");
  await update(() => state.fork());
  const forkPopup = popups.at(-1)!;
  assert.equal(forkPopup.location.href, "about:blank");
  const forkRequests = ws.sent.filter((message) => message.op === "fork").length;
  await update(() => state.fork());
  assert.equal(ws.sent.filter((message) => message.op === "fork").length, forkRequests, "duplicate clicks must share a pending fork");
  await receive({ kind: "event", sessionId: "current-session", evt: { kind: "error", message: "unrelated agent error" } });
  await receive({ kind: "error", op: "fork", sessionId: "old-session", message: "late fork failure" });
  await receive({ kind: "session-forked", session: child("late-child", "old-session") });
  assert.equal(state.forkPending, true, "unrelated errors and stale replies must not settle the current fork");
  assert.equal(forkPopup.closed, false);
  const reservedCount = popups.length;
  await receive({ kind: "session-forked", session: child("current-child", "current-session") });
  assert.equal(state.forkPending, false);
  assert.equal(popups.length, reservedCount, "success must use the reserved tab without another popup request");
  assert.equal(forkPopup.location.href, "/s/current-child");
  assert.equal(forkPopup.focuses, 1);
  await update(() => state.fork());
  const failedPopup = popups.at(-1)!;
  await receive({ kind: "error", op: "fork", sessionId: "current-session", message: "current fork failure" });
  assert.equal(state.forkPending, false);
  assert.equal(failedPopup.closed, true);
  blocked = true;
  await update(() => state.fork());
  await receive({ kind: "session-forked", session: child("blocked-child", "current-session") });
  assert.deepEqual(navigations, ["/s/blocked-child"], "a blocked popup must still provide navigation to the child");
  blocked = false;

  await update(() => state.handoff());
  const handoffPopup = popups.at(-1)!;
  const handoffRequests = ws.sent.filter((message) => message.op === "handoff").length;
  await update(() => state.handoff());
  assert.equal(ws.sent.filter((message) => message.op === "handoff").length, handoffRequests);
  await receive({ kind: "error", op: "handoff", sessionId: "old-session", message: "late handoff failure" });
  assert.equal(state.handoffPending, true, "an old handoff error must not close a newer reserved tab");
  assert.equal(handoffPopup.closed, false);
  const replacement = replacementSocket();
  await update(() => ws.close());
  assert.equal(state.handoffPending, false, "disconnect must release the pending handoff for retry");
  assert.equal(handoffPopup.closed, true);
  ws = await replacement;
  await update(() => ws.open());
  assert.deepEqual(ws.sent.at(-1), { op: "subscribe", sessionId: "current-session" });
  await update(() => state.handoff());
  const retriedPopup = popups.at(-1)!;
  await receive({ kind: "session-handoff", sourceSessionId: "current-session", session: child("handoff-child", "current-session") });
  assert.equal(state.handoffPending, false);
  assert.equal(retriedPopup.location.href, "/s/handoff-child");
  assert.equal(retriedPopup.focuses, 1);
  await update(() => state.fork());
  const disconnectedForkPopup = popups.at(-1)!;
  await update(() => ws.close());
  assert.equal(state.forkPending, false);
  assert.equal(disconnectedForkPopup.closed, true);
  assert.equal(forkPopup.closed, false, "disconnect must preserve a completed fork tab");
  assert.equal(retriedPopup.closed, false, "disconnect must preserve a completed handoff tab");
  await update(() => state.fork());
  assert.equal(popups.at(-1)!.closed, true, "a failed fork send must close its reservation");
  await update(() => state.handoff());
  assert.equal(popups.at(-1)!.closed, true, "a failed handoff send must close its reservation");
  assert.equal(state.forkPending, false);
  assert.equal(state.handoffPending, false);
  ws = await replacementSocket();
  await update(() => ws.open());
  await update(() => { state.fork(); state.handoff(); });
  const pendingTabs = popups.slice(-2);
  assert.ok(pendingTabs.every((popup) => !popup.closed));
  await act(async () => { renderer!.unmount(); });
  renderer = undefined;
  assert.ok(pendingTabs.every((popup) => popup.closed), "unmount must close both pending action tabs");
  console.log("Real React fork/handoff lifecycle: stale replies, reserved tabs, duplicate clicks, failure and disconnect recovery: OK");
} finally {
  clearTimeout(reconnectTimer);
  if (renderer) await act(async () => { renderer!.unmount(); });
  assert.equal(timers.size, 0);
  for (const [key, descriptor] of descriptors) {
    if (descriptor) Object.defineProperty(globalThis, key, descriptor);
    else delete (globalThis as any)[key];
  }
}
