import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { join } from "node:path";
import { handleSessionMessage } from "../server";
import { piAdapter } from "../adapters/pi";

const originalMethods = { send: piAdapter.send, stop: piAdapter.stop, dispose: piAdapter.dispose, listOptions: piAdapter.listOptions, refreshOptions: piAdapter.refreshOptions };
const originalSetTimeout = globalThis.setTimeout;
const originalClearTimeout = globalThis.clearTimeout;
const originalDateNow = Date.now;
const timerDescriptor = Object.getOwnPropertyDescriptor(globalThis, "setTimeout")!;
const expiryTimers = new Map<number, () => void>();
let nextExpiry = -1;
Object.defineProperty(globalThis, "setTimeout", { ...timerDescriptor, value(callback: () => void, delay: number, ...args: any[]) {
  // The start-request retention timers are not the behavior under test. Keep
  // them controllable without altering filesystem/subprocess deadlines.
  if (delay === 60_000) { const id = nextExpiry--; expiryTimers.set(id, callback); return id; }
  return originalSetTimeout(callback, delay, ...args);
} });
async function bounded<T>(promise: Promise<T>): Promise<T> {
  let guard: ReturnType<typeof setTimeout>;
  try {
    return await Promise.race([promise, new Promise<never>((_, reject) => {
      guard = originalSetTimeout(() => reject(new Error("server startup fixture did not respond")), 2_000);
    })]);
  } finally { originalClearTimeout(guard!); }
}

const replies: any[] = [];
const awaiting = new Map<string, (reply: any) => void>();
const ws = {
  data: { subscribed: null },
  send(data: string) {
    const reply = JSON.parse(data); replies.push(reply);
    if (reply.kind === "session-created" || reply.kind === "start-stopped" || (reply.kind === "error" && reply.op === "start")) awaiting.get(reply.requestId)?.(reply);
    return 0;
  },
} as unknown as Parameters<typeof handleSessionMessage>[0];
const sends: { session: any; prompt: string }[] = [];
const stops: string[] = [];
const sessions: any[] = [];
piAdapter.send = async (session, prompt) => { sessions.push(session); sends.push({ session, prompt }); };
piAdapter.stop = (session) => { stops.push(session.id); };
piAdapter.dispose = () => {};
piAdapter.listOptions = async () => [];
piAdapter.refreshOptions = async () => {};
let root: string | undefined;
function start(prompt: string, requestId: string) {
  const reply = new Promise<any>((resolve) => { awaiting.set(requestId, resolve); });
  const finished = handleSessionMessage(ws, { op: "start", provider: "pi", cwd: root, prompt, requestId });
  return Promise.all([reply, finished]).then(([reply]) => reply);
}
try {
  const scratch = join(import.meta.dir, "../scratch");
  await mkdir(scratch, { recursive: true });
  root = await mkdtemp(join(scratch, "pending-start-stop-"));
  const cancelledId = crypto.randomUUID();
  const cancelled = start("never execute this prompt", cancelledId);
  handleSessionMessage(ws, { op: "stop", requestId: cancelledId });
  assert.deepEqual(replies.at(-1), { kind: "start-stopped", requestId: cancelledId });
  const cancelledReply = await bounded(cancelled);
  assert.equal(cancelledReply.kind, "start-stopped");
  assert.equal(sends.length, 0, "Stop during actual cwd preflight must prevent the first provider send");
  assert.equal(stops.length, 0, "cancellation before creation needs no provider process");
  assert.equal((await bounded(start("do not replay", cancelledId))).kind, "start-stopped");
  assert.equal(sends.length, 0, "replaying a canceled startup must not create a session");

  const racedId = crypto.randomUUID();
  const created = await bounded(start("creation wins this race", racedId));
  assert.equal(created.kind, "session-created");
  assert.equal(sends.length, 1);
  handleSessionMessage(ws, { op: "stop", requestId: racedId });
  assert.deepEqual(stops, [created.session.id], "a request-ID stop must reach a session whose creation reply was delayed");
  handleSessionMessage(ws, { op: "stop", requestId: racedId });
  assert.equal(stops.length, 1, "retries acknowledge an accepted stop without interrupting the provider again");
  assert.equal((await bounded(start("duplicate", racedId))).session.id, created.session.id);
  assert.equal(sends.length, 1);

  const next = await bounded(start("a later prompt still runs", crypto.randomUUID()));
  assert.equal(next.kind, "session-created");
  assert.equal(sends.length, 2);
  assert.equal(sends[1].prompt, "a later prompt still runs");
  handleSessionMessage(ws, { op: "stop", sessionId: next.session.id });
  assert.deepEqual(stops, [created.session.id, next.session.id]);
  const slowId = crypto.randomUUID();
  const slow = start("canceled preflight must survive cache pruning", slowId);
  handleSessionMessage(ws, { op: "stop", requestId: slowId });
  Date.now = () => originalDateNow() + 120_000;
  const independent = start("another startup triggers cache pruning", crypto.randomUUID());
  Date.now = originalDateNow;
  assert.equal((await bounded(slow)).kind, "start-stopped");
  assert.equal((await bounded(independent)).kind, "session-created");
  assert.equal(sends.length, 3, "request retention must not forget cancellation while preflight is still pending");
  assert.equal(sends[2].prompt, "another startup triggers cache pruning");
  const missingId = crypto.randomUUID();
  handleSessionMessage(ws, { op: "stop", requestId: missingId });
  assert.deepEqual(replies.at(-1), { kind: "start-stopped", requestId: missingId }, "expired or unknown startup IDs settle the retry queue");
  assert.equal(stops.length, 2);
  console.log("Server startup cancellation prevents dispatch, reaches created sessions, deduplicates retries, and permits later starts: OK");
} finally {
  // Prompt attribution reads real local Git state; finish those owned reads
  // before removing the temporary working directory.
  await Promise.allSettled(sessions.flatMap((session) => [...(session.internal.turnBaselines?.values() ?? [])]));
  for (const session of sessions) handleSessionMessage(ws, { op: "delete", sessionId: session.id });
  Object.assign(piAdapter, originalMethods);
  Date.now = originalDateNow;
  for (const callback of expiryTimers.values()) callback();
  Object.defineProperty(globalThis, "setTimeout", timerDescriptor);
  if (root) await rm(root, { recursive: true, force: true });
}
