import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { ensureTranscriptSessionForTest } from "../server";
import { focusTranscriptTerminal, setTranscriptRpcForTest, transcriptAdapter } from "../adapters/transcript";
import type { TranscriptSource } from "../transcript-sources";
import type { CmuxRpcResult } from "../cmux-rpc";
import type { SessionCtx } from "../types";

const sessions: SessionCtx[] = [];
let root: string | undefined;
try {
  const scratch = join(import.meta.dir, "../scratch");
  await mkdir(scratch, { recursive: true });
  root = await mkdtemp(join(scratch, "terminal-rebind-"));
  for (const agent of ["claude", "codex"] as const) {
    const path = join(root, `${agent}.jsonl`);
    await writeFile(path, "");
    const source: TranscriptSource = { agent, path, sessionId: crypto.randomUUID(), surfaceId: "old-terminal", updatedAt: 1 };
    const sess = ensureTranscriptSessionForTest(source);
    sessions.push(sess);
    sess.events.push({ kind: "user", text: "existing history" });
    const attachment = sess.internal.transcript;

    let finishOldFocus!: (result: CmuxRpcResult) => void;
    setTranscriptRpcForTest(() => new Promise((resolve) => { finishOldFocus = resolve; }));
    const oldFocus = focusTranscriptTerminal(sess);

    const reopened = ensureTranscriptSessionForTest({ ...source, surfaceId: "new-terminal", updatedAt: 2 });
    assert.equal(reopened, sess, "reopening preserves the session and its subscribers");
    assert.equal(sess.internal.transcript, attachment, "rebinding does not restart transcript history");
    const calls: { method: string; params: Record<string, unknown> }[] = [];
    setTranscriptRpcForTest(async (method, params) => { calls.push({ method, params }); return { ok: true }; });
    await focusTranscriptTerminal(reopened);
    assert.deepEqual(calls, [{ method: "surface.focus", params: { surface_id: "new-terminal" } }], "reopening the same transcript must focus its current terminal");
    finishOldFocus({ ok: false, error: "old terminal disappeared" });
    await oldFocus;
    assert.deepEqual(sess.events, [{ kind: "user", text: "existing history" }], "the previous terminal's reply must not contaminate the reopened view");

    // Repeated resolution with identical IDs must not discard a valid reply.
    setTranscriptRpcForTest(() => new Promise((resolve) => { finishOldFocus = resolve; }));
    const currentFocus = focusTranscriptTerminal(sess);
    ensureTranscriptSessionForTest({ ...source, surfaceId: "new-terminal", updatedAt: 3 });
    finishOldFocus({ ok: false, error: "current terminal failed" });
    await currentFocus;
    assert.equal(sess.events.length, 2, "unchanged bindings still report their own failures");

    const detached = ensureTranscriptSessionForTest({ ...source, surfaceId: undefined, updatedAt: 4 });
    calls.length = 0;
    setTranscriptRpcForTest(async (method, params) => { calls.push({ method, params }); return { ok: true }; });
    const detachedFocus = await focusTranscriptTerminal(detached);
    assert.equal(detachedFocus.ok, false, "a removed surface must not retain a focus destination");
    assert.deepEqual(calls, [], "a removed binding must never focus the stale terminal");
    transcriptAdapter.dispose(sess);
  }
  console.log("Reopening Claude and Codex transcripts refreshes terminal focus without resetting history or accepting stale failures: OK");
} finally {
  setTranscriptRpcForTest(null);
  for (const sess of sessions) transcriptAdapter.dispose(sess);
  if (root) await rm(root, { recursive: true, force: true });
}
