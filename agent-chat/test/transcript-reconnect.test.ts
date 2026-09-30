import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { ensureTranscriptSessionForTest, handleMessageForTest } from "../server";
import { setTranscriptRpcForTest, transcriptAdapter, type TranscriptTail } from "../adapters/transcript";
import type { TranscriptSource } from "../transcript-sources";
import type { SessionCtx } from "../types";

const priorHooks = process.env.CMUX_AGENT_HOOK_STATE_DIR;
const priorClaude = process.env.CMUX_CLAUDE_HOOK_STATE_PATH;
const sessions: SessionCtx[] = [];
let root: string | undefined;
try {
  const scratch = join(import.meta.dir, "../scratch");
  await mkdir(scratch, { recursive: true });
  root = await mkdtemp(join(scratch, "transcript-reconnect-"));
  process.env.CMUX_AGENT_HOOK_STATE_DIR = root;
  delete process.env.CMUX_CLAUDE_HOOK_STATE_PATH;
  await Promise.all(["claude", "codex"].map((agent) => writeFile(join(root!, `${agent}-hook-sessions.json`), "{}")));
  for (const agent of ["claude", "codex"] as const) {
    const oldPath = join(root, `${agent}-old.jsonl`);
    const newPath = join(root, `${agent}-new.jsonl`);
    await Promise.all([oldPath, newPath].map((path) => writeFile(path, "")));
    const source: TranscriptSource = { agent, path: oldPath, sessionId: crypto.randomUUID(), surfaceId: "OLD-SURFACE", updatedAt: 1 };
    const sess = ensureTranscriptSessionForTest(source);
    sessions.push(sess);
    await (sess.internal.transcript as { tail: TranscriptTail }).tail.poll();
    sess.events.push({ kind: "user", text: "cached history" });
    const attachment = sess.internal.transcript;
    const messages: any[] = [];
    const ws = {
      data: { subscribed: null as string | null },
      send(payload: string) { messages.push(JSON.parse(payload)); return 1; },
    } as unknown as Parameters<typeof handleMessageForTest>[0];
    const subscribe = () => { messages.length = 0; handleMessageForTest(ws, { op: "subscribe", sessionId: sess.id }); };
    const store = join(root, `${agent}-hook-sessions.json`);
    const record = async (path: string) => writeFile(store, JSON.stringify({ sessions: {
      [source.sessionId]: { surfaceId: "NEW-SURFACE", transcriptPath: path, updatedAt: 2 },
    } }));
    await record(oldPath);
    subscribe();
    assert.equal(ws.data.subscribed, sess.id);
    assert.deepEqual(messages.find((message) => message.kind === "history")?.events, [{ kind: "user", text: "cached history" }]);
    assert.equal(sess.internal.transcript, attachment, "same-path reconnect preserves the existing reader");
    const calls: Record<string, unknown>[] = [];
    setTranscriptRpcForTest(async (method, params) => { calls.push({ method, ...params }); return { ok: true }; });
    handleMessageForTest(ws, { op: "focus-terminal", sessionId: sess.id });
    await Promise.resolve();
    assert.equal(calls[0]?.surface_id, "NEW-SURFACE", "reconnecting a cached transcript must refresh its terminal binding");

    // Reconnection must also reattach if the hook now points at another file.
    await record(newPath);
    subscribe();
    await (sess.internal.transcript as { tail: TranscriptTail }).tail.poll();
    assert.deepEqual(messages.find((message) => message.kind === "history")?.events, [], "the old file's history must not replay after transcript redirection");
    const line = agent === "claude"
      ? { type: "user", uuid: "fresh", message: { role: "user", content: "new transcript input" } }
      : { type: "event_msg", payload: { type: "user_message", message: "new transcript input" } };
    await writeFile(newPath, JSON.stringify(line) + "\n");
    await (sess.internal.transcript as { tail: TranscriptTail }).tail.poll();
    assert.equal(messages.some((message) => message.kind === "event" && message.evt?.text === "new transcript input"), true, "the connected page receives events from the new transcript");

    // A temporarily unavailable hook record must not discard usable history.
    await writeFile(store, "{}");
    subscribe();
    assert.equal(messages.some((message) => message.kind === "no-session"), false);
    assert.equal(messages.find((message) => message.kind === "history")?.events.some((event: any) => event.text === "new transcript input"), true);
    handleMessageForTest(ws, { op: "delete", sessionId: sess.id });
    transcriptAdapter.dispose(sess);
  }
  const missingMessages: any[] = [];
  const missingWs = { data: { subscribed: null }, send(payload: string) { missingMessages.push(JSON.parse(payload)); return 1; } } as unknown as Parameters<typeof handleMessageForTest>[0];
  handleMessageForTest(missingWs, { op: "subscribe", sessionId: "t-missing-session-id" });
  assert.deepEqual(missingMessages, [{ kind: "no-session", sessionId: "t-missing-session-id" }]);
  console.log("Claude and Codex reconnects refresh cached bindings and transcript paths, stream new history, and retain cached history on hook misses: OK");
} finally {
  setTranscriptRpcForTest(null);
  for (const sess of sessions) transcriptAdapter.dispose(sess);
  if (priorHooks === undefined) delete process.env.CMUX_AGENT_HOOK_STATE_DIR;
  else process.env.CMUX_AGENT_HOOK_STATE_DIR = priorHooks;
  if (priorClaude === undefined) delete process.env.CMUX_CLAUDE_HOOK_STATE_PATH;
  else process.env.CMUX_CLAUDE_HOOK_STATE_PATH = priorClaude;
  if (root) await rm(root, { recursive: true, force: true });
}
