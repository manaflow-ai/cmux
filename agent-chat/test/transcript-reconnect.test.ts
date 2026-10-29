// A transcript chat page reconnecting to a cached terminal session: the same
// transcript keeps its reader, history and hook attention (#15891), a moved
// transcript replaces the old history, and a missing hook record keeps what
// the page already has. A same-path reconnect from another terminal surface
// re-targets focus-terminal at the new surface (#16070).
import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { handleSessionMessage } from "../server";
import { setTranscriptRpcForTest } from "../adapters/transcript";

const priorHooks = process.env.CMUX_AGENT_HOOK_STATE_DIR;
const priorClaude = process.env.CMUX_CLAUDE_HOOK_STATE_PATH;
const opened: string[] = [];
const messages: any[] = [];
const rpcCalls: { method: string; params: any }[] = [];
// One page per session: moving a page to another session would schedule the
// old one's five-minute idle dispose and keep this script alive.
const page = () => ({
  data: { subscribed: null as string | null },
  send(payload: string) { messages.push(JSON.parse(payload)); return 1; },
}) as unknown as Parameters<typeof handleSessionMessage>[0];
const ws = page();
const history = () => [...messages].reverse().find((message) => message.kind === "history");
const texts = (events: any[] | undefined) => (events ?? []).map((event) => event.text).filter(Boolean);
async function until(check: () => boolean, label: string) {
  const deadline = Date.now() + 5_000;
  while (!check()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${label}`);
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
}

let root: string | undefined;
try {
  // Queued-message reads go to the cmux control socket; keep them local.
  setTranscriptRpcForTest(async (method, params) => {
    rpcCalls.push({ method, params });
    return { ok: true, result: { messages: [] } };
  });
  const scratch = join(import.meta.dir, "../scratch");
  await mkdir(scratch, { recursive: true });
  root = await mkdtemp(join(scratch, "transcript-reconnect-"));
  process.env.CMUX_AGENT_HOOK_STATE_DIR = root;
  delete process.env.CMUX_CLAUDE_HOOK_STATE_PATH;
  await Promise.all(["claude", "codex"].map((agent) => writeFile(join(root!, `${agent}-hook-sessions.json`), "{}")));

  for (const agent of ["claude", "codex"] as const) {
    const userLine = (text: string) => JSON.stringify(agent === "claude"
      ? { type: "user", uuid: crypto.randomUUID(), message: { role: "user", content: text } }
      : { type: "event_msg", payload: { type: "user_message", message: text } }) + "\n";
    const oldPath = join(root, `${agent}-old.jsonl`);
    const newPath = join(root, `${agent}-new.jsonl`);
    await writeFile(oldPath, userLine("old transcript input"));
    await writeFile(newPath, "");
    const agentSessionId = crypto.randomUUID();
    const sessionId = `t-${agentSessionId}`;
    const store = join(root, `${agent}-hook-sessions.json`);
    const record = (path: string, extra: Record<string, unknown> = {}) => writeFile(store, JSON.stringify({ sessions: {
      [agentSessionId]: { surfaceId: "SURFACE", transcriptPath: path, updatedAt: 2, ...extra },
    } }));
    const ws = page();
    const subscribe = () => {
      messages.length = 0;
      handleSessionMessage(ws, { op: "subscribe", sessionId });
    };

    await record(oldPath);
    subscribe();
    opened.push(sessionId);
    assert.equal(ws.data.subscribed, sessionId);
    await until(() => messages.some((message) => message.kind === "event" && message.evt?.text === "old transcript input"), `${agent} initial history`);

    // Same path: the cached reader and its history stay, and the hook's
    // attention reaches the page in the history reply (#15891).
    await record(oldPath, { runtimeStatus: "needsInput", lastBody: "Allow Bash?" });
    subscribe();
    assert.deepEqual(texts(history()?.events), ["old transcript input"], "same-path reconnect keeps cached history without a replay");
    assert.equal(history()?.session?.attention, "Allow Bash?", "same-path reconnect restores terminal attention");

    // Same path, but the agent resumed in another surface: focus-terminal
    // (and sends and queued-message reads) must follow the new surface.
    await record(oldPath, { surfaceId: "SURFACE-RESUMED" });
    subscribe();
    assert.deepEqual(texts(history()?.events), ["old transcript input"], "surface change keeps cached history");
    rpcCalls.length = 0;
    handleSessionMessage(ws, { op: "focus-terminal", sessionId });
    await until(() => rpcCalls.some((call) => call.method === "surface.focus"), `${agent} focus-terminal`);
    assert.deepEqual(rpcCalls.find((call) => call.method === "surface.focus")?.params, { surface_id: "SURFACE-RESUMED" },
      "focus-terminal targets the surface the agent resumed in");

    // The hook now points at another file: the old history is dropped and the
    // page streams the new transcript.
    await record(newPath);
    subscribe();
    assert.deepEqual(texts(history()?.events), [], "the old file's history must not replay after transcript redirection");
    await writeFile(newPath, userLine("new transcript input"));
    await until(() => messages.some((message) => message.kind === "event" && message.evt?.text === "new transcript input"), `${agent} redirected transcript event`);

    // A temporarily unavailable hook record must not discard usable history.
    await writeFile(store, "{}");
    subscribe();
    assert.equal(messages.some((message) => message.kind === "no-session"), false);
    assert.deepEqual(texts(history()?.events), ["new transcript input"]);
  }

  messages.length = 0;
  handleSessionMessage(ws, { op: "subscribe", sessionId: "t-missing-session-id" });
  assert.deepEqual(messages, [{ kind: "no-session", sessionId: "t-missing-session-id" }]);
  console.log("Claude and Codex reconnects keep same-path history and attention, follow a resumed surface, a moved transcript, and keep history on hook misses: OK");
} finally {
  for (const sessionId of opened) handleSessionMessage(ws, { op: "delete", sessionId });
  setTranscriptRpcForTest(null);
  if (priorHooks === undefined) delete process.env.CMUX_AGENT_HOOK_STATE_DIR;
  else process.env.CMUX_AGENT_HOOK_STATE_DIR = priorHooks;
  if (priorClaude === undefined) delete process.env.CMUX_CLAUDE_HOOK_STATE_PATH;
  else process.env.CMUX_CLAUDE_HOOK_STATE_PATH = priorClaude;
  if (root) await rm(root, { recursive: true, force: true });
}
