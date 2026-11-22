import { afterEach, describe, expect, test } from "bun:test";
import { appendFileSync, mkdirSync, mkdtempSync, renameSync, rmSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { attachTranscript, transcriptAdapter, TranscriptTail } from "../adapters/transcript";
import type { AgentEvent, SessionCtx } from "../types";

const roots: string[] = [];
function fixture() {
  const scratch = join(import.meta.dir, "../scratch");
  mkdirSync(scratch, { recursive: true });
  const root = mkdtempSync(join(scratch, "transcript-replacement-"));
  roots.push(root);
  return join(root, "transcript.jsonl");
}
function replace(path: string, bytes: string | Uint8Array, preserveTimes = false) {
  const previous = statSync(path);
  writeFileSync(`${path}.next`, bytes);
  if (preserveTimes) utimesSync(`${path}.next`, previous.atime, previous.mtime);
  renameSync(`${path}.next`, path);
  expect(statSync(path).ino).not.toBe(previous.ino);
}
afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

describe("transcript file replacement", () => {
  test("follows a replacement with the same size and timestamp", async () => {
    const path = fixture();
    writeFileSync(path, '{"old":1}\n');
    utimesSync(path, 1_700_000_000, 1_700_000_000);
    const seen: string[] = [];
    const tail = new TranscriptTail(path, (lines) => seen.push(...lines));
    await tail.poll();
    const before = statSync(path);
    replace(path, '{"new":2}\n', true);
    expect(statSync(path).size).toBe(before.size);
    expect(statSync(path).mtimeMs).toBe(before.mtimeMs);
    await tail.poll();
    expect(seen).toEqual(['{"old":1}', '{"new":2}']);
    await tail.poll();
    expect(seen).toHaveLength(2);
  });

  test("follows a larger replacement from its own start", async () => {
    const path = fixture();
    writeFileSync(path, '{"old":1}\n');
    const seen: string[] = [];
    const tail = new TranscriptTail(path, (lines) => seen.push(...lines));
    await tail.poll();
    replace(path, '{"new":2}\n{"next":3}\n');
    await tail.poll();
    expect(seen).toEqual(['{"old":1}', '{"new":2}', '{"next":3}']);
    appendFileSync(path, '{"appended":4}\n');
    await tail.poll();
    expect(seen.at(-1)).toBe('{"appended":4}');
    expect(seen).toHaveLength(4);
  });

  test("does not join an old partial UTF-8 line to a replacement", async () => {
    const path = fixture();
    writeFileSync(path, Buffer.concat([Buffer.from('{"old":"'), Buffer.from([0xe2, 0x82])]));
    const seen: string[] = [];
    const tail = new TranscriptTail(path, (lines) => seen.push(...lines));
    await tail.poll();
    expect(seen).toEqual([]);
    replace(path, '{"new":"🙂"}\n');
    await tail.poll();
    expect(seen).toEqual(['{"new":"🙂"}']);
  });

  test("preserves partial UTF-8 decoding for ordinary appends", async () => {
    const path = fixture();
    writeFileSync(path, Buffer.concat([Buffer.from('{"text":"'), Buffer.from([0xe2, 0x82])]));
    const seen: string[] = [];
    const tail = new TranscriptTail(path, (lines) => seen.push(...lines));
    await tail.poll();
    appendFileSync(path, Buffer.concat([Buffer.from([0xac]), Buffer.from('"}\n')]));
    await tail.poll();
    expect(seen).toEqual(['{"text":"€"}']);
  });

  test("applies the bounded initial window to a replacement", async () => {
    const path = fixture();
    writeFileSync(path, '{"old":1}\n');
    const seen: string[] = [];
    const tail = new TranscriptTail(path, (lines) => seen.push(...lines), { initialWindowBytes: 40 });
    await tail.poll();
    replace(path, `${"x".repeat(200)}\n{"keep":1}\n`);
    await tail.poll();
    expect(seen).toEqual(['{"old":1}', '{"keep":1}']);
  });

  test("remembers an empty replacement before its first append", async () => {
    const path = fixture();
    writeFileSync(path, '{"old":"unfinished');
    const seen: string[] = [];
    const tail = new TranscriptTail(path, (lines) => seen.push(...lines));
    await tail.poll();
    replace(path, "");
    await tail.poll();
    appendFileSync(path, '{"new":1}\n');
    await tail.poll();
    expect(seen).toEqual(['{"new":1}']);
  });

  test.each(["claude", "codex"] as const)("attached %s view receives events after replacement", async (agent) => {
    const path = fixture();
    const record = (id: string, text: string) => agent === "claude"
      ? { type: "user", uuid: id, message: { role: "user", content: text } }
      : { type: "event_msg", payload: { type: "user_message", message: text } };
    writeFileSync(path, JSON.stringify(record("old", "old")) + "\n");
    const sess = {
      events: [] as AgentEvent[], internal: {} as Record<string, unknown>,
      emit(event: AgentEvent) { this.events.push(event); }, setStatus() {},
    } as unknown as SessionCtx;
    const tail = attachTranscript(sess, agent, path, undefined, { pollMs: 10_000 });
    try {
      await tail.poll();
      replace(path, JSON.stringify(record("new", "new content after replacement")) + "\n");
      await tail.poll();
      expect(sess.events).toEqual([
        { kind: "user", text: "new content after replacement" },
      ]);
    } finally {
      transcriptAdapter.dispose(sess);
    }
  });

  test.each(["claude", "codex"] as const)("%s replaces copied history without duplicating the open view", async (agent) => {
    const path = fixture();
    const row = (id: string, text: string) => agent === "claude"
      ? { type: "user", uuid: id, message: { role: "user", content: text } }
      : { type: "event_msg", payload: { type: "user_message", message: text } };
    const original = [row("old-1", "first"), row("old-2", "second")].map((entry) => JSON.stringify(entry)).join("\n") + "\n";
    writeFileSync(path, original);
    const sess = {
      events: [] as AgentEvent[], internal: {} as Record<string, unknown>,
      emit(event: AgentEvent) { this.events.push(event); }, setStatus() {},
    } as unknown as SessionCtx;
    const tail = attachTranscript(sess, agent, path, undefined, { pollMs: 10_000 });
    try {
      await tail.poll();
      replace(path, original + JSON.stringify(row("new", "third")) + "\n");
      await tail.poll();
      expect(sess.events).toEqual([
        { kind: "user", text: "first" }, { kind: "user", text: "second" }, { kind: "user", text: "third" },
      ]);
    } finally {
      transcriptAdapter.dispose(sess);
    }
  });

  test("notifies subscribed views of the reset before replaying replacement events", async () => {
    const { emitSessionEventForTest, resetSessionHistory } = await import("../server");
    const path = fixture();
    const row = (text: string) => JSON.stringify({ type: "event_msg", payload: { type: "user_message", message: text } }) + "\n";
    const original = row("first") + row("second");
    writeFileSync(path, original);
    const messages: any[] = [];
    const sess = {
      id: "t-replacement", provider: "codex", cwd: join(path, ".."), title: "fixture", status: "idle",
      autoApprove: false, startOptions: {}, events: [], internal: {}, createdAt: 0,
      adapter: transcriptAdapter, transcript: { agent: "codex", path },
      sockets: new Set([{ send(data: any) { messages.push(JSON.parse(String(data))); return 1; } }]),
      resetHistory() { resetSessionHistory(sess); },
      emit(event: AgentEvent) { emitSessionEventForTest(sess, event); },
      setStatus(status: SessionCtx["status"]) { sess.status = status; },
    } as unknown as Parameters<typeof resetSessionHistory>[0];
    const tail = attachTranscript(sess, "codex", path, undefined, { pollMs: 10_000 });
    try {
      await tail.poll();
      messages.length = 0;
      replace(path, original + row("third"));
      await tail.poll();
      expect(messages[0]).toMatchObject({ kind: "history", sessionId: sess.id, events: [] });
      expect(messages.filter((message) => message.kind === "history")).toHaveLength(1);
      expect(messages.filter((message) => message.kind === "event").map((message) => message.evt.text)).toEqual(["first", "second", "third"]);
      expect(sess.internal.eventGenerations).toEqual([0, 0, 0]);
      messages.length = 0;
      replace(path, "");
      await tail.poll();
      expect(sess.events).toEqual([]);
      expect(messages).toHaveLength(1);
      expect(messages[0]).toMatchObject({ kind: "history", sessionId: sess.id, events: [] });
    } finally {
      transcriptAdapter.dispose(sess);
    }
  });
});
