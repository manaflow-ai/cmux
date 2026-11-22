import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { join } from "node:path";
import { createElement } from "react";
import { act, create, type ReactTestRenderer } from "react-test-renderer";

const keys = ["window", "document", "location", "history", "sessionStorage", "WebSocket", "setTimeout", "clearTimeout", "IS_REACT_ACT_ENVIRONMENT"];
const descriptors = new Map(keys.map((key) => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
const originalSetTimeout = globalThis.setTimeout;
const originalClearTimeout = globalThis.clearTimeout;
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
function timer(delay: number) {
  const match = [...timers].filter(([, timer]) => timer.delay === delay);
  assert.equal(match.length, 1);
  return { id: match[0][0], ...match[0][1] };
}

let renderer: ReactTestRenderer | undefined;
let fixtureRoot: string | undefined;
let restoreProvider: (() => void) | undefined;
let cleanSessions: (() => Promise<void>) | undefined;
try {
  const { useSession, composerDraftKey } = await import("../src/session");
  let state: ReturnType<typeof useSession>;
  function Harness() { state = useSession(); return null; }
  const update = async (callback: () => void) => { await act(async () => { callback(); }); };
  await act(async () => { renderer = create(createElement(Harness)); });
  let ws = sockets.at(-1)!;
  await update(() => ws.open());
  const start = async (prompt: string) => {
    await update(() => { assert.equal(state.start({ provider: "fixture", cwd: "/fixture", prompt }), true); });
    return ws.sent.at(-1);
  };
  const acknowledge = async (requestId: string) => update(() => ws.receive({ kind: "start-stopped", requestId }));
  const fire = async (deadline: ReturnType<typeof timer>) => update(() => { timers.delete(deadline.id); deadline.run(); });
  const reconnect = async () => {
    const retry = timer(800);
    await fire(retry);
    ws = sockets.at(-1)!;
    await update(() => ws.open());
  };

  const first = await start("timed-out initial prompt");
  await update(() => state.reply("queued follow-up"));
  const firstDeadline = timer(30_000);
  await fire(firstDeadline);
  assert.deepEqual(ws.sent.at(-1), { op: "stop", requestId: first.requestId }, "a timed-out startup must cancel the original server request before offering a retry");
  assert.equal(state.phase, "composer");
  assert.equal(drafts.get(composerDraftKey), "timed-out initial prompt\n\nqueued follow-up");
  assert.match(state.lastError, /timed out/);
  await acknowledge(first.requestId);

  const newer = await start("new startup after timeout");
  await update(firstDeadline.run);
  assert.equal(state.session?.id, `pending-${newer.requestId}`, "a queued old timeout must not cancel a newer startup");
  assert.equal(ws.sent.at(-1), newer);
  const acceptedDeadline = timer(30_000);
  const accepted = { id: "accepted", provider: "fixture", cwd: "/fixture", title: "accepted", status: "running" };
  await update(() => ws.receive({ kind: "session-created", requestId: newer.requestId, session: accepted }));
  await update(acceptedDeadline.run);
  assert.equal(state.session?.id, accepted.id);
  assert.equal(state.phase, "chat");
  assert.equal(timers.size, 0);
  await update(() => state.compose());

  const reconnecting = await start("same startup through reconnect");
  const beforeReconnect = timer(30_000);
  await update(() => ws.close());
  await reconnect();
  const afterReconnect = timer(30_000);
  await update(beforeReconnect.run);
  assert.equal(state.session?.id, `pending-${reconnecting.requestId}`, "a canceled deadline from the prior socket must not expire the rearmed request");
  assert.equal(timer(30_000).id, afterReconnect.id);
  await fire(afterReconnect);
  assert.deepEqual(ws.sent.at(-1), { op: "stop", requestId: reconnecting.requestId });
  await acknowledge(reconnecting.requestId);

  const offline = await start("timeout while offline");
  const offlineDeadline = timer(30_000);
  await update(() => ws.close());
  await fire(offlineDeadline);
  assert.equal(state.phase, "composer");
  assert.equal(drafts.get(composerDraftKey), "timeout while offline");
  await reconnect();
  assert.deepEqual(ws.sent, [{ op: "stop", requestId: offline.requestId }], "reconnect must retry cancellation and never replay a timed-out prompt");
  await acknowledge(offline.requestId);

  const failed = await start("failed startup");
  const failedDeadline = timer(30_000);
  await update(() => ws.receive({ kind: "error", op: "start", requestId: failed.requestId, message: "startup failed" }));
  assert.deepEqual(ws.sent.at(-1), { op: "stop", requestId: failed.requestId });
  await acknowledge(failed.requestId);
  const retry = await start("retry after failure");
  await update(failedDeadline.run);
  assert.equal(state.session?.id, `pending-${retry.requestId}`);
  assert.equal(state.lastError, "");
  await update(() => state.stop());
  await acknowledge(retry.requestId);

  // Exercise the exact server handler with real directory preflight while the
  // client times out in the same synchronous turn. No provider prompt should
  // be sent after preflight finishes, even though its original start arrived.
  const { handleSessionMessage } = await import("../server");
  const { piAdapter } = await import("../adapters/pi");
  const original = { send: piAdapter.send, listOptions: piAdapter.listOptions, refreshOptions: piAdapter.refreshOptions, dispose: piAdapter.dispose };
  restoreProvider = () => { Object.assign(piAdapter, original); };
  const dispatched: any[] = [];
  piAdapter.send = async (session) => { dispatched.push(session); };
  piAdapter.listOptions = async () => [];
  piAdapter.refreshOptions = async () => {};
  piAdapter.dispose = () => {};
  const serverReplies: any[] = [];
  const serverSocket = {
    data: { subscribed: null },
    send(data: string) { const reply = JSON.parse(data); serverReplies.push(reply); ws.receive(reply); return 0; },
  } as unknown as Parameters<typeof handleSessionMessage>[0];
  cleanSessions = async () => {
    await Promise.allSettled(dispatched.flatMap((session) => [...(session.internal.turnBaselines?.values() ?? [])]));
    for (const session of dispatched) handleSessionMessage(serverSocket, { op: "delete", sessionId: session.id });
  };
  const scratch = join(import.meta.dir, "../scratch");
  await mkdir(scratch, { recursive: true });
  fixtureRoot = await mkdtemp(join(scratch, "startup-timeout-"));
  let serverRequestId: string;
  await act(async () => {
    assert.equal(state.start({ provider: "pi", cwd: fixtureRoot!, prompt: "never dispatch after timeout" }), true);
    const request = ws.sent.at(-1);
    serverRequestId = request.requestId;
    const flight = handleSessionMessage(serverSocket, request);
    state.reply("preserve this queued follow-up");
    const deadline = timer(30_000);
    timers.delete(deadline.id); deadline.run();
    handleSessionMessage(serverSocket, ws.sent.at(-1));
    let guard: ReturnType<typeof setTimeout>;
    try {
      await Promise.race([flight, new Promise<never>((_, reject) => {
        guard = originalSetTimeout(() => reject(new Error("server preflight fixture did not finish")), 2_000);
      })]);
    } finally { originalClearTimeout(guard!); }
  });
  assert.equal(dispatched.length, 0, "timeout cancellation must prevent dispatch through the actual server startup path");
  assert.ok(serverReplies.some((reply) => reply.kind === "start-stopped" && reply.requestId === serverRequestId));
  assert.ok(!serverReplies.some((reply) => reply.kind === "session-created"));
  assert.equal(state.phase, "composer");
  assert.match(state.lastError, /timed out/);
  assert.equal(drafts.get(composerDraftKey), "never dispatch after timeout\n\npreserve this queued follow-up");
  // Retention timers belong to the server fixture, rather than the mounted
  // client; expire them explicitly before checking the view's cleanup.
  for (const [id, expiry] of timers) {
    if (expiry.delay === 60_000) { timers.delete(id); expiry.run(); }
  }
  console.log("Startup timeout cancellation, queued drafts, stale deadlines, rearmed requests, offline recovery, and failure retry: OK");
} finally {
  if (renderer) await act(async () => { renderer!.unmount(); });
  await cleanSessions?.();
  restoreProvider?.();
  if (fixtureRoot) await rm(fixtureRoot, { recursive: true, force: true });
  for (const [key, descriptor] of descriptors) {
    if (descriptor) Object.defineProperty(globalThis, key, descriptor);
    else delete (globalThis as any)[key];
  }
  assert.equal(timers.size, 0);
}
