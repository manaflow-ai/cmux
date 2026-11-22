import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { attachTranscript, transcriptAdapter, TranscriptTail, type TranscriptAgent } from "../adapters/transcript";
import type { AgentEvent, SessionCtx, SessionStatus } from "../types";

const descriptors = new Map(["setInterval", "clearInterval"].map((key) => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
const intervals = new Map<number, { callback: () => void; delay: number }>();
let nextInterval = 1;
Object.defineProperty(globalThis, "setInterval", { configurable: true, writable: true, value(callback: () => void, delay: number) {
  const id = nextInterval++; intervals.set(id, { callback, delay }); return id;
} });
Object.defineProperty(globalThis, "clearInterval", { configurable: true, writable: true, value(id: number) { intervals.delete(id); } });

const tails: TranscriptTail[] = [];
const reads: Promise<void>[] = [];
let root: string | undefined;
const poll = (tail: TranscriptTail) => { const read = tail.poll(); reads.push(read); return read; };
const remember = (tail: TranscriptTail) => { tails.push(tail); return tail; };
const user = (agent: TranscriptAgent, id: string, text: string) => agent === "claude"
  ? { type: "user", uuid: id, message: { role: "user", content: text } }
  : { type: "event_msg", payload: { type: "user_message", message: text } };
const title = (agent: TranscriptAgent, text: string) => agent === "claude"
  ? { type: "ai-title", aiTitle: text }
  : { type: "event_msg", payload: { type: "thread_name_updated", thread_name: text } };
const jsonl = (...records: unknown[]) => records.map((record) => JSON.stringify(record)).join("\n") + "\n";
function session() {
  const statuses: SessionStatus[] = [];
  const sess = {
    events: [] as AgentEvent[], internal: {} as Record<string, unknown>,
    emit(event: AgentEvent) { this.events.push(event); },
    setStatus(status: SessionStatus) { statuses.push(status); },
  } as unknown as SessionCtx;
  return { sess, statuses };
}

try {
  const scratch = join(import.meta.dir, "../scratch");
  await mkdir(scratch, { recursive: true });
  root = await mkdtemp(join(scratch, "transcript-disposal-"));
  for (const agent of ["claude", "codex"] as const) {
    const path = join(root, `${agent}-disposed.jsonl`);
    await writeFile(path, jsonl(user(agent, "old", "disposed content"), title(agent, "disposed title")));
    const { sess, statuses } = session();
    const titles: string[] = [];
    let ticks = 0;
    const tail = remember(attachTranscript(sess, agent, path, (next) => titles.push(next), { pollMs: 10_000, onTick: () => ticks++ }));
    const activeRead = poll(tail);
    transcriptAdapter.dispose(sess);
    await activeRead;
    assert.deepEqual(sess.events, [], "a disposed transcript read must not emit late events");
    assert.deepEqual(titles, [], "a disposed transcript read must not rename the view");
    assert.deepEqual(statuses, []);
    assert.equal(ticks, 0);
    assert.equal(intervals.size, 0);
  }

  for (const agent of ["claude", "codex"] as const) {
    const oldPath = join(root, `${agent}-old.jsonl`);
    const newPath = join(root, `${agent}-new.jsonl`);
    await writeFile(oldPath, jsonl(user(agent, "old", "old content"), title(agent, "old title")));
    await writeFile(newPath, jsonl(user(agent, "new", "new content"), title(agent, "new title")));
    const { sess } = session();
    const titles: string[] = [];
    let oldTicks = 0;
    let newTicks = 0;
    const oldTail = remember(attachTranscript(sess, agent, oldPath, (next) => titles.push(next), { pollMs: 10_000, onTick: () => oldTicks++ }));
    const oldStatus = [...intervals.values()].find((interval) => interval.delay === 2_000)!.callback;
    const oldRead = poll(oldTail);
    transcriptAdapter.dispose(sess);
    const newTail = remember(attachTranscript(sess, agent, newPath, (next) => titles.push(next), { pollMs: 10_000, onTick: () => newTicks++ }));
    await Promise.all([oldRead, poll(newTail)]);
    assert.deepEqual(sess.events, [{ kind: "user", text: "new content" }], "old reads must not append to a redirected session");
    assert.deepEqual(titles, ["new title"]);
    assert.equal(oldTicks, 0);
    assert.ok(newTicks > 0);
    oldStatus();
    assert.equal(oldTicks, 0, "a retained old status callback must not inspect the new attachment");
    transcriptAdapter.dispose(sess);
    assert.equal(intervals.size, 0);
  }

  const restartPath = join(root, "restart.jsonl");
  await writeFile(restartPath, '{"line":1}\n');
  const restartedLines: string[] = [];
  const restart = remember(new TranscriptTail(restartPath, (lines) => restartedLines.push(...lines), { pollMs: 10_000 }));
  const oldRead = poll(restart);
  restart.stop();
  restart.start();
  const newRead = poll(restart);
  assert.notEqual(newRead, oldRead, "restart must not join the canceled read from the previous lifetime");
  await Promise.all([oldRead, newRead]);
  assert.deepEqual(restartedLines, ['{"line":1}']);
  restart.stop();
  await poll(restart);
  assert.deepEqual(restartedLines, ['{"line":1}']);
  assert.equal(intervals.size, 0);

  const burstPath = join(root, "burst.jsonl");
  const rows = Array.from({ length: 256 }, (_, index) => JSON.stringify({ index, text: "x".repeat(16_384) }));
  await writeFile(burstPath, rows.join("\n") + "\n");
  const received: string[] = [];
  let batches = 0;
  const burst = remember(new TranscriptTail(burstPath, (lines) => {
    batches++; received.push(...lines);
    if (batches === 1) burst.stop();
  }, { pollMs: 10_000 }));
  await poll(burst);
  assert.equal(batches, 1, "stop during delivery must prevent reading more chunks");
  assert.ok(received.length > 0 && received.length < rows.length);
  burst.start();
  await poll(burst);
  assert.deepEqual(received, rows, "restart resumes at the last delivered byte offset without duplicating rows");
  burst.stop();

  const batchPath = join(root, "dispose-in-batch.jsonl");
  await writeFile(batchPath, jsonl(user("claude", "first", "first"), user("claude", "second", "second"), title("claude", "stale title")));
  const { sess, statuses } = session();
  sess.emit = (event) => { sess.events.push(event); transcriptAdapter.dispose(sess); };
  const titles: string[] = [];
  const batch = remember(attachTranscript(sess, "claude", batchPath, (next) => titles.push(next), { pollMs: 10_000 }));
  await poll(batch);
  assert.deepEqual(sess.events, [{ kind: "user", text: "first" }], "disposal during a batch must stop remaining event delivery");
  assert.deepEqual(titles, []);
  assert.deepEqual(statuses, []);
  assert.equal(intervals.size, 0, "all owned timers are released");
  console.log("Transcript disposal, redirected views, retained status callbacks, chunk cancellation, and immediate restart: OK");
} finally {
  for (const tail of tails) tail.stop();
  await Promise.allSettled(reads);
  if (root) await rm(root, { recursive: true, force: true });
  for (const [key, descriptor] of descriptors) {
    if (descriptor) Object.defineProperty(globalThis, key, descriptor);
    else delete (globalThis as any)[key];
  }
}
