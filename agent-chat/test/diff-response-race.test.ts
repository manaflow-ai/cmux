import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { createElement } from "react";
import { act, create, type ReactTestRenderer } from "react-test-renderer";

const globalKeys = ["window", "document", "location", "history", "sessionStorage", "WebSocket", "IS_REACT_ACT_ENVIRONMENT"];
const descriptors = new Map(globalKeys.map((key) => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
const timers = new Map<number, () => void>();
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
  close() { this.readyState = 3; this.onclose?.(); }
  receive(message: unknown) { this.onmessage?.({ data: JSON.stringify(message) } as MessageEvent); }
}
for (const [key, value] of Object.entries({
  window: {
    setTimeout(callback: () => void) { const id = nextTimer++; timers.set(id, callback); return id; },
    clearTimeout(id: number) { timers.delete(id); },
  },
  document: { title: "cmux agent" }, location,
  history: { replaceState(_state: unknown, _unused: string, path: string) { location.pathname = path; } },
  sessionStorage: { setItem() {} }, WebSocket: FakeSocket, IS_REACT_ACT_ENVIRONMENT: true,
})) Object.defineProperty(globalThis, key, { configurable: true, writable: true, value });

let renderer: ReactTestRenderer | undefined;
let gitFixture: string | undefined;
try {
  const { useSession, fileDiffCacheKey } = await import("../src/session");
  let state: ReturnType<typeof useSession>;
  function Harness() { state = useSession(); return null; }
  const update = async (callback: () => void) => { await act(async () => { callback(); }); };
  await act(async () => { renderer = create(createElement(Harness)); });
  const ws = sockets.at(-1)!;
  await update(() => { ws.readyState = FakeSocket.OPEN; ws.onopen?.(); });
  const receive = async (message: unknown) => update(() => ws.receive(message));
  const history = async () => receive({ kind: "history", sessionId: "current",
    session: { id: "current", provider: "fixture", cwd: "/fixture", title: "fixture", status: "idle" }, events: [] });
  await history();
  const firstKey = fileDiffCacheKey("1", "tracked.txt");
  const secondKey = fileDiffCacheKey("2", "tracked.txt");
  await update(() => { state.requestFileDiff("current", firstKey); state.requestFileDiff("current", secondKey); });
  const [first, second] = ws.sent.slice(-2);
  await receive({ kind: "file-diff", sessionId: "current", path: "tracked.txt", requestId: second.requestId ?? "second", diff: "second snapshot" });
  assert.equal(state.fileDiffs[secondKey], "second snapshot", "a later diff request completing first must populate its own cache entry");
  assert.equal(state.fileDiffs[firstKey], undefined);
  await receive({ kind: "file-diff", sessionId: "current", path: "tracked.txt", requestId: first.requestId, diff: "first snapshot" });
  assert.equal(state.fileDiffs[firstKey], "first snapshot");
  assert.ok(first.requestId && second.requestId && first.requestId !== second.requestId);
  await receive({ kind: "file-diff", sessionId: "current", path: "tracked.txt", requestId: second.requestId, diff: "duplicate response" });
  assert.equal(state.fileDiffs[secondKey], "second snapshot");
  console.log("reversed same-path diff replies populate their own revision cache entries: OK");

  const errorKey = fileDiffCacheKey("3", "tracked.txt");
  await update(() => state.requestFileDiff("current", errorKey));
  const request = ws.sent.at(-1);
  await receive({ kind: "error", op: "get-file-diff", sessionId: "old-session", path: "tracked.txt", requestId: request.requestId, message: "stale error" });
  assert.equal(state.fileDiffs[errorKey], undefined, "a different session's error must leave the current request pending");
  await receive({ kind: "file-diff", sessionId: "old-session", path: "tracked.txt", requestId: request.requestId, diff: "stale success" });
  assert.equal(state.fileDiffs[errorKey], undefined);
  await receive({ kind: "error", op: "get-file-diff", sessionId: "current", path: "tracked.txt", requestId: "unknown", message: "unknown request" });
  assert.equal(state.fileDiffs[errorKey], undefined);
  await receive({ kind: "error", op: "get-file-diff", sessionId: "current", path: "tracked.txt", requestId: request.requestId, message: "matching error" });
  assert.equal(state.fileDiffErrors[errorKey], "matching error");
  assert.equal(state.fileDiffs[errorKey], undefined);

  const replacedKey = fileDiffCacheKey("4", "tracked.txt");
  await update(() => state.requestFileDiff("current", replacedKey));
  const replaced = ws.sent.at(-1);
  await history();
  await update(() => state.requestFileDiff("current", firstKey));
  const replacement = ws.sent.at(-1);
  await receive({ kind: "file-diff", sessionId: "current", path: "tracked.txt", requestId: replaced.requestId, diff: "before history replacement" });
  assert.deepEqual(state.fileDiffs, {}, "old replies must not consume a request after history replacement");
  await receive({ kind: "file-diff", sessionId: "current", path: "tracked.txt", requestId: replacement.requestId, diff: "after history replacement" });
  assert.equal(state.fileDiffs[firstKey], "after history replacement");
  // Exercise the same server response path the WebSocket handler invokes,
  // including a real Git diff and every validation/error exit.
  const { sendFileDiffResponse, recordFilesChangedForTest } = await import("../server");
  await mkdir(join(import.meta.dir, "../scratch"), { recursive: true });
  gitFixture = await mkdtemp(join(import.meta.dir, "../scratch/diff-response-"));
  const git = async (args: string[]) => {
    const proc = Bun.spawn(["git", ...args], { cwd: gitFixture, stdout: "pipe", stderr: "pipe" });
    const [code, error] = await Promise.all([proc.exited, new Response(proc.stderr).text()]);
    assert.equal(code, 0, error);
  };
  await git(["init", "--quiet"]);
  await writeFile(join(gitFixture, "tracked.txt"), "before\n");
  await git(["add", "tracked.txt"]);
  await git(["-c", "user.name=cmux test", "-c", "user.email=cmux-test@example.invalid", "commit", "--quiet", "-m", "fixture"]);
  await writeFile(join(gitFixture, "tracked.txt"), "after\n");
  const sess = { id: "current", cwd: gitFixture, internal: {} };
  recordFilesChangedForTest(sess, [{ path: "tracked.txt", adds: 1, dels: 1, status: "modified" }]);
  const replies: any[] = [];
  const socket = { data: { subscribed: "current" as string | null }, send(data: any) { replies.push(JSON.parse(String(data))); return 1; } };
  const invoke = async (path: string, requestId: string, session: typeof sess | null = sess) => {
    const msg = { sessionId: "current", path, requestId };
    await sendFileDiffResponse(socket, msg, session ?? undefined);
    const response = replies.at(-1);
    assert.equal(response.requestId, requestId, "every server diff response must preserve request identity");
    assert.equal(response.sessionId, "current");
    return response;
  };
  const success = await invoke("./tracked.txt", "success");
  assert.equal(success.kind, "file-diff");
  assert.equal(success.path, "tracked.txt");
  assert.match(success.diff, /\+after/);
  const originalError = console.error;
  const expectedErrors: unknown[][] = [];
  try {
    console.error = (...args) => { expectedErrors.push(args); };
    for (const path of ["", "../outside", "not-reported.txt"]) {
      assert.equal((await invoke(path, `invalid:${path}`)).kind, "error");
    }
    assert.equal((await invoke("tracked.txt", "missing-session", null)).kind, "error");
    socket.data.subscribed = "different";
    assert.equal((await invoke("tracked.txt", "wrong-subscription")).kind, "error");
    socket.data.subscribed = "current";
    assert.equal((await invoke("tracked.txt", "git-error", { ...sess, cwd: join(gitFixture, "missing-cwd") })).kind, "error");
  } finally {
    console.error = originalError;
  }
  assert.equal(expectedErrors.length, 6);
  await sendFileDiffResponse(socket, { sessionId: "current", path: "tracked.txt" }, sess);
  assert.equal(replies.at(-1).kind, "file-diff", "older callers without request IDs still receive a response");
  assert.equal(replies.at(-1).requestId, undefined);
  const normalizedKey = fileDiffCacheKey("5", "./tracked.txt");
  await update(() => state.requestFileDiff("current", normalizedKey));
  await sendFileDiffResponse(socket, ws.sent.at(-1), sess);
  await receive(replies.at(-1));
  assert.match(state.fileDiffs[normalizedKey], /\+after/, "a real server reply with a normalized path reaches the originating client cache entry");
  await act(async () => { renderer!.unmount(); });
  renderer = undefined;
  assert.equal(timers.size, 0);
  console.log("server diff success, normalized path, and validation failures echo request IDs: OK");
} finally {
  if (renderer) await act(async () => { renderer!.unmount(); });
  if (gitFixture) await rm(gitFixture, { recursive: true, force: true });
  for (const [key, descriptor] of descriptors) {
    if (descriptor) Object.defineProperty(globalThis, key, descriptor);
    else delete (globalThis as any)[key];
  }
}
