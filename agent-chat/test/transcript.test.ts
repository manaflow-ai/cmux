import { afterEach, describe, expect, test } from "bun:test";
import { appendFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { attachTranscript, focusTranscriptTerminal, parseTranscriptText, setTranscriptRpcForTest, transcriptAdapter, TranscriptTail, transcriptLooksRunning, toolDetail } from "../adapters/transcript";
import { utimesSync } from "node:fs";
import type { SessionCtx, SessionStatus } from "../types";
import { claudeProjectSlug, resolveSessionTranscript, resolveSurfaceTranscript, transcriptAttention } from "../transcript-sources";
import type { AgentEvent } from "../types";

const jsonl = (...rows: unknown[]) => rows.map((r) => JSON.stringify(r)).join("\n") + "\n";

const temps: string[] = [];
function tempDir(): string {
  const dir = mkdtempSync(join(tmpdir(), "agent-chat-transcript-"));
  temps.push(dir);
  return dir;
}
afterEach(() => {
  for (const dir of temps.splice(0)) rmSync(dir, { recursive: true, force: true });
});

describe("Claude transcript parser", () => {
  const claude = jsonl(
    { type: "user", uuid: "u1", cwd: "/work/app", message: { role: "user", content: "fix the flaky test" }, origin: { kind: "human" } },
    { type: "user", uuid: "m1", isMeta: true, message: { role: "user", content: "<system-reminder>hidden</system-reminder>" } },
    { type: "assistant", uuid: "a1", message: { content: [{ type: "thinking", thinking: "look at the test first" }] } },
    { type: "assistant", uuid: "a2", message: { content: [{ type: "tool_use", id: "t1", name: "Bash", input: { command: "bun test flaky", description: "run" } }] } },
    { type: "assistant", uuid: "a2", message: { content: [{ type: "tool_use", id: "t1", name: "Bash", input: { command: "bun test flaky" } }] } },
    { type: "user", uuid: "r1", message: { role: "user", content: [{ type: "tool_result", tool_use_id: "t1", content: "1 fail", is_error: true }] } },
    { type: "assistant", uuid: "side", isSidechain: true, message: { content: [{ type: "text", text: "subagent chatter" }] } },
    { type: "assistant", uuid: "a3", message: { content: [{ type: "text", text: "Fixed the race in `setup`." }] } },
    { type: "system", uuid: "s1", subtype: "turn_duration", durationMs: 4200 },
    { type: "ai-title", aiTitle: "Fix flaky test" },
    { type: "user", uuid: "u2", message: { role: "user", content: "<command-name>/model</command-name>\n<command-message>model</command-message>\n<command-args>opus</command-args>" } },
    { type: "user", uuid: "u3", message: { role: "user", content: "<local-command-stdout>Set model to opus</local-command-stdout>" } },
    { type: "user", uuid: "u4", origin: { kind: "task-notification" }, message: { role: "user", content: "<task-notification><summary>Build finished</summary></task-notification>" } },
    { type: "user", uuid: "u5", origin: { kind: "peer" }, message: { role: "user", content: "Another session sent a message" } },
    { type: "user", uuid: "u6", message: { role: "user", content: [{ type: "text", text: "[Request interrupted by user]" }] } },
    { type: "assistant", uuid: "e1", isApiErrorMessage: true, message: { content: [{ type: "text", text: "API Error: overloaded" }] } },
    { type: "system", uuid: "c1", subtype: "compact_boundary", content: "Conversation compacted" },
    { type: "user", uuid: "c2", isCompactSummary: true, message: { role: "user", content: "This session is being continued..." } },
    "not json",
  );

  test("normalizes a session into AgentEvents", () => {
    const { events, title, cwd } = parseTranscriptText("claude", claude);
    expect(title).toBe("Fix flaky test");
    expect(cwd).toBe("/work/app");
    expect(events).toEqual([
      { kind: "user", text: "fix the flaky test" },
      { kind: "thinking", text: "look at the test first" },
      { kind: "tool-start", toolId: "t1", name: "Bash", detail: "bun test flaky" },
      { kind: "tool-end", toolId: "t1", ok: false, detail: "1 fail" },
      { kind: "assistant", text: "Fixed the race in `setup`." },
      { kind: "done", stats: "4.2s" },
      { kind: "user", text: "/model opus" },
      { kind: "status", text: "Set model to opus" },
      { kind: "status", text: "Background task: Build finished" },
      { kind: "status", text: "Interrupted" },
      { kind: "done" },
      { kind: "error", message: "API Error: overloaded" },
      { kind: "status", text: "Conversation compacted" },
    ] satisfies AgentEvent[]);
  });

  test("keeps a typed prompt stored after injected reminder blocks", () => {
    const { events } = parseTranscriptText("claude", jsonl(
      { type: "user", uuid: "p1", origin: { kind: "human" }, message: { role: "user", content: [
        { type: "text", text: "<system-reminder>context</system-reminder>" },
        { type: "text", text: "ship it" },
      ] } },
    ));
    expect(events).toEqual([{ kind: "user", text: "ship it" }]);
  });

  test("ends a turn at the final message's stop reason, once", () => {
    const { events } = parseTranscriptText("claude", jsonl(
      { type: "user", uuid: "p1", message: { role: "user", content: "hi" } },
      { type: "assistant", uuid: "x1", message: { id: "m1", stop_reason: "end_turn", content: [{ type: "thinking", thinking: "greet" }] } },
      { type: "assistant", uuid: "x2", message: { id: "m1", stop_reason: "end_turn", content: [{ type: "text", text: "Hello." }] } },
      { type: "system", uuid: "x3", subtype: "turn_duration", durationMs: 900 },
      { type: "user", uuid: "p2", message: { role: "user", content: "again" } },
      { type: "assistant", uuid: "x4", message: { id: "m2", stop_reason: "tool_use", content: [{ type: "text", text: "Checking." }] } },
      { type: "system", uuid: "x5", subtype: "turn_duration", durationMs: 1500 },
    ));
    expect(events).toEqual([
      { kind: "user", text: "hi" },
      { kind: "thinking", text: "greet" },
      { kind: "assistant", text: "Hello." },
      { kind: "done" },
      { kind: "user", text: "again" },
      { kind: "assistant", text: "Checking." },
      { kind: "done", stats: "1.5s" },
    ] satisfies AgentEvent[]);
  });

  test("tool detail prefers the meaningful input field", () => {
    expect(toolDetail({ file_path: "/a/b.ts", limit: 20 })).toBe("/a/b.ts");
    expect(toolDetail('{"cmd":["ls","-la"]}')).toBe("ls -la");
    expect(toolDetail({ other: 1 })).toBe('{"other":1}');
  });
});

describe("Codex rollout parser", () => {
  const codex = jsonl(
    { type: "session_meta", payload: { id: "abc", cwd: "/work/api" } },
    { type: "response_item", payload: { type: "message", role: "user", content: [{ type: "input_text", text: "<environment_context>...</environment_context>" }] } },
    { type: "event_msg", payload: { type: "user_message", message: "add a health route" } },
    { type: "event_msg", payload: { type: "item_completed", item: { type: "UserMessage", content: [{ type: "text", text: "add a health route" }] } } },
    { type: "response_item", payload: { type: "reasoning", summary: [{ type: "summary_text", text: "Check the router" }], encrypted_content: "x" } },
    { type: "response_item", payload: { type: "reasoning", summary: [], encrypted_content: "x" } },
    { type: "response_item", payload: { type: "function_call", name: "exec_command", arguments: '{"cmd":"rg router"}', call_id: "c1" } },
    { type: "response_item", payload: { type: "function_call_output", call_id: "c1", output: "src/router.ts" } },
    { type: "response_item", payload: { type: "custom_tool_call", name: "apply_patch", input: "*** Begin Patch", call_id: "c2" } },
    { type: "response_item", payload: { type: "custom_tool_call_output", call_id: "c2", output: [{ type: "input_text", text: "Success" }] } },
    { type: "response_item", payload: { type: "message", role: "assistant", content: [{ type: "output_text", text: "Added `/health`." }] } },
    { type: "event_msg", payload: { type: "task_complete" } },
    { type: "event_msg", payload: { type: "user_message", message: "add a health route" } },
  );

  test("normalizes a rollout into AgentEvents", () => {
    const { events, cwd } = parseTranscriptText("codex", codex);
    expect(cwd).toBe("/work/api");
    expect(events).toEqual([
      { kind: "user", text: "add a health route" },
      { kind: "thinking", text: "Check the router" },
      { kind: "tool-start", toolId: "c1", name: "exec_command", detail: "rg router" },
      { kind: "tool-end", toolId: "c1", detail: "src/router.ts" },
      { kind: "tool-start", toolId: "c2", name: "apply_patch", detail: "*** Begin Patch" },
      { kind: "tool-end", toolId: "c2", detail: "Success" },
      { kind: "assistant", text: "Added `/health`." },
      { kind: "done" },
      // A repeated prompt in a later turn is a real message, not a duplicate.
      { kind: "user", text: "add a health route" },
    ] satisfies AgentEvent[]);
  });
});

describe("TranscriptTail", () => {
  test("delivers complete lines as the file grows", async () => {
    const path = join(tempDir(), "t.jsonl");
    writeFileSync(path, '{"a":1}\n{"b":');
    const seen: string[] = [];
    const tail = new TranscriptTail(path, (lines) => seen.push(...lines));
    await tail.poll();
    expect(seen).toEqual(['{"a":1}']);
    appendFileSync(path, '2}\n{"c":3}\n');
    await tail.poll();
    expect(seen).toEqual(['{"a":1}', '{"b":2}', '{"c":3}']);
    await tail.poll();
    expect(seen.length).toBe(3);
  });

  test("starts long files at a line boundary inside the initial window", async () => {
    const path = join(tempDir(), "t.jsonl");
    writeFileSync(path, `${"x".repeat(100)}\n{"keep":1}\n`);
    const seen: string[] = [];
    const tail = new TranscriptTail(path, (lines) => seen.push(...lines), { initialWindowBytes: 30 });
    await tail.poll();
    expect(seen).toEqual(['{"keep":1}']);
  });

  test("follows a truncated file from its start", async () => {
    const path = join(tempDir(), "t.jsonl");
    writeFileSync(path, '{"old":1}\n{"old":2}\n');
    const seen: string[] = [];
    const tail = new TranscriptTail(path, (lines) => seen.push(...lines));
    await tail.poll();
    writeFileSync(path, '{"new":1}\n');
    await tail.poll();
    expect(seen).toEqual(['{"old":1}', '{"old":2}', '{"new":1}']);
  });
});

test("running state follows the last turn boundary and recent writes", () => {
  const now = 1_000_000;
  const turn: AgentEvent[] = [{ kind: "user", text: "go" }, { kind: "tool-start", toolId: "1", name: "Bash" }];
  expect(transcriptLooksRunning(turn, now - 1_000, now)).toBe(true);
  expect(transcriptLooksRunning([...turn, { kind: "done" }], now - 1_000, now)).toBe(false);
  expect(transcriptLooksRunning(turn, now - 120_000, now)).toBe(false);
});

test("an old transcript opens idle even when its last turn has no end", async () => {
  const path = join(tempDir(), "old.jsonl");
  writeFileSync(path, jsonl({ type: "user", uuid: "p1", message: { role: "user", content: "hi" } }));
  const dayAgo = (Date.now() - 86_400_000) / 1000;
  utimesSync(path, dayAgo, dayAgo);
  const statuses: SessionStatus[] = [];
  const sess = {
    events: [] as AgentEvent[],
    internal: {} as Record<string, unknown>,
    emit(evt: AgentEvent) { this.events.push(evt); },
    setStatus(status: SessionStatus) { statuses.push(status); },
  } as unknown as SessionCtx;
  const tail = attachTranscript(sess, "claude", path);
  await tail.poll();
  await new Promise((r) => setTimeout(r, 20));
  transcriptAdapter.dispose(sess);
  expect(sess.events).toEqual([{ kind: "user", text: "hi" }]);
  expect(statuses).not.toContain("running");
});

describe("terminal delivery", () => {
  function fakeSession(target?: { agentSessionId: string; surfaceId?: string }) {
    return {
      events: [] as AgentEvent[],
      internal: { transcriptTarget: target } as Record<string, unknown>,
      emit(evt: AgentEvent) { this.events.push(evt); },
      setStatus() {},
    } as unknown as SessionCtx;
  }
  afterEach(() => setTranscriptRpcForTest(null));

  test("send types the prompt into the terminal's agent session and echoes nothing itself", async () => {
    const calls: [string, Record<string, unknown>][] = [];
    setTranscriptRpcForTest(async (method, params) => { calls.push([method, params]); return { ok: true }; });
    const sess = fakeSession({ agentSessionId: "claude-1234", surfaceId: "SURF" });
    await transcriptAdapter.send(sess, "ship it");
    transcriptAdapter.stop(sess);
    await focusTranscriptTerminal(sess);
    expect(calls).toEqual([
      ["mobile.chat.send", { session_id: "claude-1234", text: "ship it" }],
      ["mobile.chat.interrupt", { session_id: "claude-1234" }],
      ["surface.focus", { surface_id: "SURF" }],
    ]);
    expect(sess.events).toEqual([]);
  });

  test("delivery failures surface as errors in the view", async () => {
    setTranscriptRpcForTest(async () => ({ ok: false, error: "not_found" }));
    const sess = fakeSession({ agentSessionId: "claude-1234" });
    await transcriptAdapter.send(sess, "hi");
    expect(sess.events).toEqual([{ kind: "error", message: "Couldn't send to the terminal: not_found", prompt: "hi" }]);
    expect((await focusTranscriptTerminal(sess)).ok).toBe(false);
  });
});

describe("transcript sources", () => {
  function fixture() {
    const home = tempDir();
    const claudeConfigDir = join(home, "claude-config");
    const codexHome = join(home, "codex-home");
    mkdirSync(join(home, ".cmuxterm"), { recursive: true });
    const recorded = join(home, "recorded.jsonl");
    writeFileSync(recorded, "");
    const projectDir = join(claudeConfigDir, "projects", claudeProjectSlug("/work/app.v2"));
    mkdirSync(projectDir, { recursive: true });
    writeFileSync(join(projectDir, "claude-fallback-0001.jsonl"), "");
    const rolloutDir = join(codexHome, "sessions", "2026", "09", "27");
    mkdirSync(rolloutDir, { recursive: true });
    const rollout = join(rolloutDir, "rollout-2026-09-27T10-00-00-codex-session-0001.jsonl");
    writeFileSync(rollout, "");
    writeFileSync(join(home, ".cmuxterm", "claude-hook-sessions.json"), JSON.stringify({
      activeSessionsBySurface: { "aaaaaaaa-0000-0000-0000-000000000001": { sessionId: "claude-active-0001" } },
      sessions: {
        "claude-active-0001": { surfaceId: "AAAAAAAA-0000-0000-0000-000000000001", transcriptPath: recorded, updatedAt: 10 },
        "claude-newer-0001": { surfaceId: "AAAAAAAA-0000-0000-0000-000000000001", transcriptPath: recorded, updatedAt: 99 },
        "claude-fallback-0001": { surfaceId: "BBBBBBBB-0000-0000-0000-000000000002", cwd: "/work/app.v2", updatedAt: 5 },
        "claude-missing-0001": { surfaceId: "DDDDDDDD-0000-0000-0000-000000000004", transcriptPath: join(home, "gone.jsonl"), updatedAt: 5, runtimeStatus: "needsInput", lastBody: "Claude needs your permission to use Bash" },
        "../escape": { surfaceId: "EEEEEEEE-0000-0000-0000-000000000005", transcriptPath: recorded, updatedAt: 5 },
      },
    }));
    writeFileSync(join(home, ".cmuxterm", "codex-hook-sessions.json"), JSON.stringify({
      sessions: {
        "codex-session-0001": { surfaceId: "CCCCCCCC-0000-0000-0000-000000000003", cwd: "/work/api", updatedAt: 7 },
      },
    }));
    return { env: { home, claudeConfigDir, codexHome }, recorded, projectDir, rollout };
  }

  test("the surface's active binding wins over newer history", () => {
    const { env, recorded } = fixture();
    const source = resolveSurfaceTranscript("aaaaaaaa-0000-0000-0000-000000000001", env);
    expect(source).toMatchObject({ agent: "claude", sessionId: "claude-active-0001", path: recorded });
  });

  test("falls back to each agent's default transcript layout", () => {
    const { env, projectDir, rollout } = fixture();
    expect(resolveSurfaceTranscript("BBBBBBBB-0000-0000-0000-000000000002", env)?.path).toBe(join(projectDir, "claude-fallback-0001.jsonl"));
    expect(resolveSurfaceTranscript("CCCCCCCC-0000-0000-0000-000000000003", env)).toMatchObject({ agent: "codex", path: rollout, cwd: "/work/api" });
    expect(resolveSessionTranscript("codex-session-0001", env)?.path).toBe(rollout);
  });

  test("reports what the agent waits on in the terminal", () => {
    const { env } = fixture();
    expect(transcriptAttention("claude", "claude-missing-0001", env)).toBe("Claude needs your permission to use Bash");
    expect(transcriptAttention("claude", "claude-active-0001", env)).toBeNull();
  });

  test("returns nothing for unknown surfaces, missing files, and invalid ids", () => {
    const { env } = fixture();
    expect(resolveSurfaceTranscript("FFFFFFFF-0000-0000-0000-000000000006", env)).toBeNull();
    expect(resolveSurfaceTranscript("DDDDDDDD-0000-0000-0000-000000000004", env)).toBeNull();
    expect(resolveSurfaceTranscript("EEEEEEEE-0000-0000-0000-000000000005", env)).toBeNull();
    expect(resolveSessionTranscript("../escape", env)).toBeNull();
  });
});
