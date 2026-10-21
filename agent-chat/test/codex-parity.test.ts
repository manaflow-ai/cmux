import { expect, test } from "bun:test";
import { codexEventsForTest } from "../adapters/codex";

const threadId = "thread-parity";
const turnId = "turn-parity";

function notification(method: string, params: Record<string, unknown> = {}) {
  return { method, params: { threadId, turnId, ...params } };
}

test("Codex app-server stream normalizes into the shared AgentEvent contract", () => {
  const events = codexEventsForTest([
    // These lifecycle/diagnostic notifications are intentionally not UI events.
    notification("thread/status/changed", { status: { type: "active", activeFlags: [] } }),
    notification("hook/started", { hook: { name: "check" } }),
    notification("hook/completed", { hook: { name: "check" } }),
    notification("account/rateLimits/updated", { rateLimits: { primary: { remaining: 1 } } }),
    notification("thread/tokenUsage/updated", { tokenUsage: { total: { inputTokens: 12, outputTokens: 7 } } }),
    notification("turn/started", { turn: { id: turnId } }),
    notification("item/started", {
      item: { type: "commandExecution", id: "command-1", command: "echo parity" },
    }),
    notification("item/completed", {
      item: { type: "commandExecution", id: "command-1", status: "completed", exitCode: 0, aggregatedOutput: "ok" },
    }),
    notification("item/started", {
      item: { type: "agentMessage", id: "message-1", text: "" },
    }),
    notification("item/reasoning/delta", { itemId: "reasoning-1", delta: "planning" }),
    notification("item/agentMessage/delta", { itemId: "message-1", delta: "CAN" }),
    notification("item/agentMessage/delta", { itemId: "message-1", delta: "ARY" }),
    notification("item/completed", {
      item: { type: "agentMessage", id: "message-1", text: "CANARY", phase: "final_answer" },
    }),
    notification("turn/completed", { turn: { id: turnId, durationMs: 1200 } }),
  ]);

  // Assertions inspect only the shared normalized contract; raw app-server
  // payloads above are fixtures, never part of the parity receipt.
  expect(events).toEqual([
    { kind: "tool-start", toolId: "command-1", name: "shell", detail: "echo parity" },
    { kind: "tool-end", toolId: "command-1", name: "shell", ok: true, detail: "ok" },
    { kind: "thinking", text: "planning" },
    { kind: "delta", text: "CAN" },
    { kind: "delta", text: "ARY" },
    { kind: "done", stats: "12 in · 7 out · 1.2s" },
  ]);
});

test("Codex app-server failures stay visible as error then done", () => {
  const events = codexEventsForTest([
    notification("turn/started", { turn: { id: turnId } }),
    notification("turn/failed", { error: { message: "provider unavailable" } }),
  ]);

  expect(events).toEqual([
    { kind: "error", message: "provider unavailable" },
    { kind: "done" },
  ]);
});
