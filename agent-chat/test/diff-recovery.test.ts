import assert from "node:assert/strict";
import { createElement } from "react";
import { act, create, type ReactTestRenderer } from "react-test-renderer";

const globalKeys = ["window", "document", "location", "history", "sessionStorage", "WebSocket", "setTimeout", "clearTimeout", "IS_REACT_ACT_ENVIRONMENT"];
const descriptors = new Map(globalKeys.map((key) => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
const timers = new Map<number, { callback: () => void; delay: number }>();
const sockets: FakeSocket[] = [];
let nextTimer = 1;
const location = { pathname: "/s/current", protocol: "http:", host: "fixture", search: "" };
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
const timerApi = {
  setTimeout(callback: () => void, delay: number) { const id = nextTimer++; timers.set(id, { callback, delay }); return id; },
  clearTimeout(id: number) { timers.delete(id); },
};
for (const [key, value] of Object.entries({
  window: timerApi, ...timerApi,
  document: { title: "cmux agent" }, location,
  history: { replaceState(_state: unknown, _unused: string, path: string) { location.pathname = path; } },
  sessionStorage: { setItem() {} }, WebSocket: FakeSocket, IS_REACT_ACT_ENVIRONMENT: true,
})) Object.defineProperty(globalThis, key, { configurable: true, writable: true, value });

let renderer: ReactTestRenderer | undefined;
try {
  const { useSession, fileDiffCacheKey } = await import("../src/session");
  let state: ReturnType<typeof useSession>;
  let renders = 0;
  function Harness() { renders++; state = useSession(); return null; }
  const errors = () => (state as typeof state & { fileDiffErrors?: Record<string, string> }).fileDiffErrors ?? {};
  const update = async (callback: () => void) => { await act(async () => { callback(); }); };
  await act(async () => { renderer = create(createElement(Harness)); });
  let ws = sockets.at(-1)!;
  await update(() => ws.open());
  const receive = async (message: unknown) => update(() => ws.receive(message));
  const history = async () => receive({ kind: "history", sessionId: "current",
    session: { id: "current", provider: "fixture", cwd: "/fixture", title: "fixture", status: "idle" }, events: [] });
  const deadlines = () => [...timers.entries()].filter(([, timer]) => timer.delay === 30_000);
  const fire = async (id: number) => update(() => { const timer = timers.get(id)!; timers.delete(id); timer.callback(); });
  await history();
  const key = fileDiffCacheKey("1", "tracked.txt");
  await update(() => state.requestFileDiff("current", key));
  const first = ws.sent.at(-1);
  assert.equal(deadlines().length, 1, "diff loading needs a bounded deadline instead of an indefinite spinner");
  const staleTimeout = deadlines()[0]![1].callback;
  await update(() => state.requestFileDiff("current", key));
  assert.equal(ws.sent.at(-1), first, "repeated opens share the pending request");
  await fire(deadlines()[0]![0]);
  assert.ok(errors()[key], "a timed-out diff has a recoverable error");
  assert.equal(state.fileDiffs[key], undefined, "errors must not be displayed as diff code");
  await update(() => state.requestFileDiff("current", key));
  const retry = ws.sent.at(-1);
  assert.notEqual(retry.requestId, first.requestId);
  assert.equal(errors()[key], undefined);
  await update(staleTimeout);
  assert.equal(deadlines().length, 1, "an old timeout must not fail the retry");
  await receive({ kind: "file-diff", sessionId: "current", path: "tracked.txt", requestId: first.requestId, diff: "late response" });
  assert.equal(state.fileDiffs[key], undefined);
  await receive({ kind: "file-diff", sessionId: "current", path: "tracked.txt", requestId: retry.requestId, diff: "retry diff" });
  assert.equal(state.fileDiffs[key], "retry diff");
  assert.equal(deadlines().length, 0);

  const errorKey = fileDiffCacheKey("2", "tracked.txt");
  await update(() => state.requestFileDiff("current", errorKey));
  await receive({ kind: "error", op: "get-file-diff", sessionId: "current", path: "tracked.txt", requestId: ws.sent.at(-1).requestId, message: "Couldn't load this file" });
  assert.equal(errors()[errorKey], "Couldn't load this file");
  assert.equal(state.fileDiffs[errorKey], undefined);
  assert.equal(deadlines().length, 0);

  const interruptedKey = fileDiffCacheKey("3", "tracked.txt");
  await update(() => state.requestFileDiff("current", interruptedKey));
  const interruptedTimeout = deadlines()[0]![1].callback;
  await update(() => ws.close());
  assert.ok(errors()[interruptedKey], "disconnect must end diff loading immediately");
  assert.equal(deadlines().length, 0);
  const offlineKey = fileDiffCacheKey("4", "tracked.txt");
  await update(() => state.requestFileDiff("current", offlineKey));
  assert.ok(errors()[offlineKey], "opening a diff while disconnected must give a retryable error");
  assert.equal(deadlines().length, 0);
  await update(interruptedTimeout);
  const reconnect = [...timers.entries()].find(([, timer]) => timer.delay === 800)!;
  await fire(reconnect[0]);
  ws = sockets.at(-1)!;
  await update(() => ws.open());
  await history();
  assert.deepEqual(errors(), {});
  await update(() => state.requestFileDiff("current", interruptedKey));
  const replacedTimeout = deadlines()[0]![1].callback;
  await history();
  assert.equal(deadlines().length, 0, "authoritative history cancels old diff deadlines");
  await update(replacedTimeout);
  assert.deepEqual(errors(), {});
  await update(() => state.requestFileDiff("current", key));
  const abandonedTimeout = deadlines()[0]![1].callback;
  await update(() => state.compose());
  assert.equal(deadlines().length, 0);
  await update(abandonedTimeout);
  assert.deepEqual(errors(), {});
  await act(async () => { renderer!.unmount(); });
  renderer = undefined;
  assert.equal(timers.size, 0);

  location.pathname = "/s/current";
  await act(async () => { renderer = create(createElement(Harness)); });
  ws = sockets.at(-1)!;
  await update(() => ws.open());
  await update(() => state.requestFileDiff("current", key));
  const disposedTimeout = deadlines()[0]![1].callback;
  await act(async () => { renderer!.unmount(); });
  renderer = undefined;
  const disposedRenders = renders;
  await update(disposedTimeout);
  assert.equal(renders, disposedRenders);
  assert.equal(timers.size, 0, "unmount must release every owned deadline");
  console.log("diff timeout, retry, disconnect, history replacement, and unmount recovery: OK");
} finally {
  if (renderer) await act(async () => { renderer!.unmount(); });
  for (const [key, descriptor] of descriptors) {
    if (descriptor) Object.defineProperty(globalThis, key, descriptor);
    else delete (globalThis as any)[key];
  }
}
