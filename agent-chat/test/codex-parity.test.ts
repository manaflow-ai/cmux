import { expect, test } from "bun:test";
import { codexEventsForTest, codexRoutingForTest } from "../adapters/codex";

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

test("Codex request_user_input reaches the person as a question instead of being declined", () => {
  const events = codexEventsForTest([{
    id: 7,
    method: "item/tool/requestUserInput",
    params: {
      threadId,
      turnId,
      itemId: "item-1",
      isBlocking: true,
      questions: [{ id: "region", header: "Region", question: "Which region?", options: [{ label: "us", description: "" }] }],
    },
  }]);

  expect(events.map((evt) => evt.kind)).toEqual(["question"]);
});

test("Codex turn plan updates become plan entries", () => {
  const events = codexEventsForTest([
    notification("turn/plan/updated", {
      explanation: "Start with the adapter",
      plan: [
        { step: "Read the adapter", status: "completed" },
        { step: "Map the notifications", status: "inProgress" },
        { step: "Add tests", status: "pending" },
      ],
    }),
    // An empty plan carries nothing to show and must not blank the last one.
    notification("turn/plan/updated", { plan: [] }),
  ]);

  expect(events).toEqual([
    {
      kind: "plan",
      entries: [
        { text: "Read the adapter", status: "completed" },
        { text: "Map the notifications", status: "in_progress" },
        { text: "Add tests", status: "pending" },
      ],
    },
  ]);
});

test("Codex compaction shows one marker whether the item, the legacy notification or both arrive", () => {
  const compactionItem = (id: string) => notification("item/completed", { item: { type: "contextCompaction", id } });
  const events = codexEventsForTest([
    notification("turn/started", { turn: { id: turnId } }),
    // A current app-server reports each compaction as an item and as the
    // deprecated thread/compacted notification, in either order.
    notification("item/started", { item: { type: "contextCompaction", id: "compact-1" } }),
    compactionItem("compact-1"),
    notification("thread/compacted"),
    notification("thread/compacted"),
    compactionItem("compact-2"),
    // An older app-server sends only the legacy notification.
    notification("thread/compacted", { turnId: "turn-legacy" }),
  ]);

  expect(events).toEqual([
    { kind: "status", text: "Conversation compacted" },
    { kind: "status", text: "Conversation compacted" },
    { kind: "status", text: "Conversation compacted" },
  ]);
});

test("Codex goal updates show once per objective and status", () => {
  const goal = (objective: string, status: string, tokensUsed: number) => notification("thread/goal/updated", {
    goal: { threadId, objective, status, tokensUsed, timeUsedSeconds: tokensUsed, createdAt: 1, updatedAt: tokensUsed },
  });
  const events = codexEventsForTest([
    goal("Ship the adapter", "active", 10),
    // Usage ticks re-send the same goal; they are not new transcript rows.
    goal("Ship the adapter", "active", 20),
    goal("Ship the adapter", "budgetLimited", 30),
    goal("Ship the adapter", "complete", 40),
    notification("thread/goal/cleared"),
    notification("thread/goal/cleared"),
  ]);

  expect(events).toEqual([
    { kind: "status", text: "Goal: Ship the adapter" },
    { kind: "status", text: "Goal reached its token budget: Ship the adapter" },
    { kind: "status", text: "Goal complete: Ship the adapter" },
    { kind: "status", text: "Goal cleared" },
  ]);
});

test("Codex thread status and archive notifications surface what the agent pane can act on", () => {
  const events = codexEventsForTest([
    // Approvals and input requests are answered at once by the adapter, so
    // the waiting flags would only leave stale rows behind.
    notification("thread/status/changed", { status: { type: "active", activeFlags: ["waitingOnApproval"] } }),
    notification("thread/status/changed", { status: { type: "systemError" } }),
    notification("thread/status/changed", { status: { type: "systemError" } }),
    notification("thread/status/changed", { status: { type: "idle" } }),
    notification("thread/status/changed", { status: { type: "systemError" } }),
    notification("thread/archived"),
    notification("thread/unarchived"),
  ]);

  expect(events).toEqual([
    { kind: "status", text: "Codex reported a system error on this thread" },
    { kind: "status", text: "Codex reported a system error on this thread" },
    { kind: "status", text: "Thread archived in Codex" },
    { kind: "status", text: "Thread unarchived in Codex" },
  ]);
});

test("Codex closing the thread ends a running turn and unroutes it so the next send resumes", () => {
  const routing = codexRoutingForTest([
    notification("turn/started", { turn: { id: turnId } }),
    notification("thread/closed"),
    // Nothing routes to the session once the server has unloaded the thread.
    notification("item/agentMessage/delta", { itemId: "late", delta: "late" }),
  ]);

  expect(routing.events).toEqual([
    { kind: "error", message: "Codex closed the thread mid-turn" },
    { kind: "done" },
  ]);
  expect(routing.routed).toBe(false);
  expect(routing.status).toBe("idle");
});
