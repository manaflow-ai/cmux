import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { attachTranscript, focusTranscriptTerminal, setTranscriptRpcForTest, transcriptAdapter, type TranscriptTail } from "../adapters/transcript";
import type { CmuxRpcResult } from "../cmux-rpc";
import type { AgentEvent, SessionCtx } from "../types";

const descriptors = new Map(["setInterval", "clearInterval"].map((key) => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
const intervals = new Set<number>();
let nextInterval = 1;
Object.defineProperty(globalThis, "setInterval", { configurable: true, writable: true, value() { const id = nextInterval++; intervals.add(id); return id; } });
Object.defineProperty(globalThis, "clearInterval", { configurable: true, writable: true, value(id: number) { intervals.delete(id); } });
function session() {
  return {
    events: [] as AgentEvent[],
    internal: { transcriptTarget: { agentSessionId: "old-agent", surfaceId: "old-surface" } } as Record<string, unknown>,
    emit(event: AgentEvent) { this.events.push(event); }, setStatus() {},
  } as unknown as SessionCtx;
}
type Action = "send" | "stop" | "focus";
function begin(sess: SessionCtx, action: Action, prompt = "old prompt") {
  let resolve!: (result: CmuxRpcResult) => void;
  const reply = new Promise<CmuxRpcResult>((done) => { resolve = done; });
  setTranscriptRpcForTest(() => reply);
  const completion = action === "send" ? transcriptAdapter.send(sess, prompt)
    : action === "focus" ? focusTranscriptTerminal(sess)
    : (transcriptAdapter.stop(sess), reply.then(() => Promise.resolve()));
  return { async fail() {
    resolve({ ok: false, error: "ETIMEDOUT", errorCode: "timeout" });
    await completion;
    await Promise.resolve();
  } };
}
const tails: TranscriptTail[] = [];
const reads: Promise<void>[] = [];
const remember = (tail: TranscriptTail) => { tails.push(tail); reads.push(tail.poll()); return tail; };
let root: string | undefined;
try {
  const scratch = join(import.meta.dir, "../scratch");
  await mkdir(scratch, { recursive: true });
  root = await mkdtemp(join(scratch, "rpc-lifetime-"));
  const oldPath = join(root, "old.jsonl");
  const newPath = join(root, "new.jsonl");
  await Promise.all([oldPath, newPath].map((path) => writeFile(path, "")));
  for (const action of ["send", "stop", "focus"] as const) {
    const disposed = session();
    const oldRequest = begin(disposed, action);
    transcriptAdapter.dispose(disposed);
    await oldRequest.fail();
    assert.deepEqual(disposed.events, [], "a disposed view must not receive a late terminal RPC failure");

    const redirected = session();
    remember(attachTranscript(redirected, "claude", oldPath));
    const oldTargetRequest = begin(redirected, action);
    transcriptAdapter.dispose(redirected);
    redirected.internal.transcriptTarget = { agentSessionId: "new-agent", surfaceId: "new-surface" };
    remember(attachTranscript(redirected, "codex", newPath));
    await oldTargetRequest.fail();
    assert.deepEqual(redirected.events, [], "an old request must not append an error to a redirected view");
    await begin(redirected, action, "new prompt").fail();
    assert.equal(redirected.events.length, 1, "the active attachment still reports its own RPC failure");
    assert.equal((redirected.events[0] as any).code, "terminal-rpc-timeout");
    if (action === "send") assert.equal((redirected.events[0] as any).prompt, "new prompt");
    transcriptAdapter.dispose(redirected);

    const mutated = session();
    const oldMutableTarget = begin(mutated, action);
    const target = mutated.internal.transcriptTarget as { agentSessionId: string; surfaceId: string };
    target.agentSessionId = "changed-agent"; target.surfaceId = "changed-surface";
    await oldMutableTarget.fail();
    assert.deepEqual(mutated.events, [], "mutating a reused target object also invalidates the original RPC");
    await begin(mutated, action).fail();
    assert.equal(mutated.events.length, 1);

    const reattached = session();
    const oldTail = remember(attachTranscript(reattached, "claude", oldPath));
    const oldState = reattached.internal.transcript as { statusTimer: ReturnType<typeof setInterval> };
    const oldAttachmentRequest = begin(reattached, action);
    // A new attachment identity must invalidate replies even when target and
    // path are identical. Release the retained old fixture handles explicitly.
    remember(attachTranscript(reattached, "claude", oldPath));
    oldTail.stop(); clearInterval(oldState.statusTimer);
    await oldAttachmentRequest.fail();
    assert.deepEqual(reattached.events, [], "reattaching the same target must not accept the old attachment's failure");
    await begin(reattached, action).fail();
    assert.equal(reattached.events.length, 1);
    transcriptAdapter.dispose(reattached);
  }
  assert.equal(intervals.size, 0);
  console.log("Late send, interrupt, and focus failures are fenced across disposal, redirection, mutable targets, and reattachment: OK");
} finally {
  setTranscriptRpcForTest(null);
  for (const tail of tails) tail.stop();
  await Promise.allSettled(reads);
  if (root) await rm(root, { recursive: true, force: true });
  for (const [key, descriptor] of descriptors) {
    if (descriptor) Object.defineProperty(globalThis, key, descriptor);
    else delete (globalThis as any)[key];
  }
}
