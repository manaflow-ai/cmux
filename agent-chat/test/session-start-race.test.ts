import assert from "node:assert/strict";
import { createElement } from "react";
import { act, create, type ReactTestRenderer } from "react-test-renderer";

const globals = ["window", "document", "location", "history", "sessionStorage", "WebSocket", "IS_REACT_ACT_ENVIRONMENT"];
const descriptors = new Map(globals.map((key) => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
const timers = new Map<number, () => void>();
const drafts = new Map<string, string>();
let nextTimer = 1;
const location = { pathname: "/", protocol: "http:", host: "fixture", search: "" };
const document = { title: "cmux agent" };
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

const fixtures: Record<string, unknown> = {
  window: {
    setTimeout(callback: () => void, delay: number) {
      assert.equal(delay, 30_000, "advance only the session startup deadline");
      const id = nextTimer++;
      timers.set(id, callback);
      return id;
    },
    clearTimeout(id: number) { timers.delete(id); },
  },
  document, location,
  history: { replaceState(_state: unknown, _unused: string, path: string) { location.pathname = path; } },
  sessionStorage: { setItem(key: string, value: string) { drafts.set(key, value); } },
  WebSocket: FakeSocket,
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const [key, value] of Object.entries(fixtures)) Object.defineProperty(globalThis, key, { configurable: true, writable: true, value });

let renderer: ReactTestRenderer | undefined;
try {
  const { useSession, composerDraftKey } = await import("../src/session");
  let state: ReturnType<typeof useSession>;
  function Harness() { state = useSession(); return null; }
  await act(async () => { renderer = create(createElement(Harness)); });
  assert.equal(sockets.length, 1);
  const ws = sockets[0]!;
  await act(async () => { ws.open(); });
  const start = async (prompt: string) => {
    await act(async () => { assert.equal(state.start({ provider: "fixture", cwd: "/fixture", prompt }), true); });
    return ws.sent.at(-1).requestId as string;
  };
  const receive = async (message: unknown) => { await act(async () => { ws.receive(message); }); };
  const summary = (id: string, title: string) => ({ id, provider: "fixture", cwd: "/fixture", title, status: "idle", createdAt: 1 });
  const oldSession = summary("abandoned-session", "abandoned chat");
  const firstRequest = await start("recover this first draft");
  assert.equal(timers.size, 1);
  await act(async () => {
    const deadline = [...timers.values()][0]!;
    timers.clear();
    deadline();
  });
  assert.equal(state.phase, "composer");
  assert.equal(drafts.get(composerDraftKey), "recover this first draft");
  const timeoutError = state.lastError;
  await receive({ kind: "session-created", requestId: firstRequest, session: oldSession });
  assert.equal(state.phase, "composer", "a late startup response must not reopen an abandoned chat");
  await receive({ kind: "history", sessionId: oldSession.id, session: oldSession, events: [{ kind: "user", text: "old history" }] });
  await receive({ kind: "no-session", sessionId: oldSession.id });
  await receive({ kind: "error", op: "start", requestId: firstRequest, message: "stale startup failure" });
  assert.equal(state.phase, "composer");
  assert.equal(state.lastError, timeoutError, "late startup errors must not replace the current failure");
  assert.equal(drafts.get(composerDraftKey), "recover this first draft");

  const secondRequest = await start("current prompt");
  await receive({ kind: "session-created", requestId: firstRequest, session: oldSession });
  await receive({ kind: "history", sessionId: oldSession.id, session: oldSession, events: [] });
  await receive({ kind: "no-session", sessionId: oldSession.id });
  await receive({ kind: "error", op: "start", requestId: firstRequest, message: "stale startup failure" });
  assert.equal(state.session?.id, `pending-${secondRequest}`, "old replies must not replace a newer pending startup");
  assert.equal(state.lastError, "", "late errors must not mark a newer startup as failed");
  assert.equal(timers.size, 1, "old replies must not cancel the newer startup deadline");
  await act(async () => { state.reply("queued follow-up"); });
  const currentSession = summary("current-session", "current chat");
  await receive({ kind: "session-created", requestId: secondRequest, session: currentSession });
  assert.equal(state.session?.id, currentSession.id);
  assert.equal(timers.size, 0);
  assert.ok(ws.sent.some((message) => message.op === "send" && message.sessionId === currentSession.id && message.prompt === "queued follow-up"));
  await receive({ kind: "history", sessionId: currentSession.id, session: currentSession, events: [{ kind: "assistant", text: "current history" }] });
  const blocks = state.blocks;
  await receive({ kind: "session-created", requestId: firstRequest, session: oldSession });
  assert.deepEqual(ws.sent.at(-1), { op: "subscribe", sessionId: currentSession.id }, "late server subscription must be repaired to the current chat");
  await receive({ kind: "history", sessionId: oldSession.id, session: oldSession, events: [] });
  await receive({ kind: "no-session", sessionId: oldSession.id });
  assert.equal(state.phase, "chat");
  assert.equal(state.session?.id, currentSession.id);
  assert.deepEqual(state.blocks, blocks);
  assert.equal(location.pathname, `/s/${currentSession.id}`);
  assert.equal(document.title, currentSession.title);
  await act(async () => { state.reply("keep going"); });
  assert.equal(ws.sent.at(-1).sessionId, currentSession.id);
  assert.equal(ws.sent.at(-1).prompt, "keep going");

  await act(async () => { state.compose(); });
  await receive({ kind: "session-created", requestId: secondRequest, session: currentSession });
  await receive({ kind: "history", sessionId: currentSession.id, session: currentSession, events: [] });
  assert.equal(state.phase, "composer", "leaving a chat must also reject late creation/history replies");
  const thirdRequest = await start("restore a failed startup");
  await receive({ kind: "error", op: "start", requestId: thirdRequest, message: "fixture startup failed" });
  await receive({ kind: "session-created", requestId: thirdRequest, session: oldSession });
  assert.equal(state.phase, "composer");
  assert.equal(drafts.get(composerDraftKey), "restore a failed startup");
  const fourthRequest = await start("valid missing session");
  await receive({ kind: "session-created", requestId: fourthRequest, session: currentSession });
  await receive({ kind: "no-session", sessionId: currentSession.id });
  assert.equal(state.phase, "composer", "a current no-session reply must still reset the chat");
  console.log("Real React session hook rejects stale startup/history replies and preserves current chat ownership: OK");
} finally {
  if (renderer) await act(async () => { renderer!.unmount(); });
  assert.equal(timers.size, 0, "unmount must clear the startup deadline");
  for (const [key, descriptor] of descriptors) {
    if (descriptor) Object.defineProperty(globalThis, key, descriptor);
    else delete (globalThis as any)[key];
  }
}
