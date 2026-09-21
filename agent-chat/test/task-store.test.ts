import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "bun:test";
import { DurableTaskStore, type DurableTaskRecord } from "../task-store";
import type { AgentEvent } from "../types";

function assert(cond: unknown, message: string): asserts cond {
  if (!cond) throw new Error(message);
}

test("persists, reloads, bounds, and removes task state", async () => {
  const dir = join(import.meta.dir, "..", "scratch", "task-store-test");
  const path = join(dir, "tasks.json");
  await rm(dir, { recursive: true, force: true });
  await mkdir(dir, { recursive: true });

  const record: DurableTaskRecord = {
  id: "task-1",
  conversationId: "conversation-1",
  provider: "codex",
  cwd: "/tmp/project",
  title: "durable task",
  status: "running",
  createdAt: 10,
  updatedAt: 11,
  autoApprove: true,
  startOptions: { model: "gpt-5" },
  parentSessionId: "parent-1",
  parentConversationId: "parent-conversation-1",
  startRequestId: "request-1",
  events: [
    { kind: "meta", providerSessionId: "provider-session-1" },
    { kind: "user", text: "hello" },
    { kind: "delta", text: "hi" },
  ],
  };

  const store = new DurableTaskStore(path, { debounceMs: 0, maxEvents: 2 });
  store.upsert(record);
  record.events.push({ kind: "error", message: "caller mutation must not leak" });
  await store.flush();
  const onDisk = JSON.parse(await readFile(path, "utf8"));
  assert(onDisk.version === 1, "journal should include a schema version");
  assert(onDisk.tasks[0].events.length === 2, "journal should cap replay events");
  assert(onDisk.tasks[0].events[1].kind === "delta", "journal should retain the newest events");

  const restored = new DurableTaskStore(path, { debounceMs: 0, maxEvents: 5 });
  const loaded = restored.get("task-1");
  assert(loaded?.conversationId === record.conversationId, "task identity should survive reload");
  assert(loaded?.parentSessionId === record.parentSessionId, "handoff lineage should survive reload");
  assert(loaded?.events.length === 2, "reloaded task should expose replay history");
  if (loaded) loaded.startOptions.model = "changed";
  assert(restored.get("task-1")?.startOptions.model === "gpt-5", "get should return a defensive copy");

  restored.remove("task-1");
  await restored.flush();
  assert(restored.list().length === 0, "remove should delete a task from the journal");

  await writeFile(path, "not json\n", "utf8");
  const corrupt = new DurableTaskStore(path);
  assert(corrupt.list().length === 0, "corrupt journal should be ignored on startup");
  await rm(dir, { recursive: true, force: true });
});

function fixture(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: "task-1", conversationId: "conversation-1", provider: "codex",
    cwd: "/tmp/project", title: "durable task", status: "idle",
    createdAt: 10, updatedAt: 11, autoApprove: true, startOptions: {},
    events: [{ kind: "user", text: "hello" }], ...overrides,
  };
}

async function withSnapshot(tasks: unknown[], check: (path: string) => Promise<void> | void) {
  const dir = await mkdtemp(join(tmpdir(), "cmux-task-store-"));
  const path = join(dir, "tasks.json");
  try {
    await writeFile(path, JSON.stringify({ version: 1, tasks }));
    await check(path);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

test("reopening with a lower event cap bounds reads and unrelated rewrites", async () => {
  const events: AgentEvent[] = [
    { kind: "user", text: "old" },
    { kind: "assistant", text: "new" },
    { kind: "done" },
  ];
  await withSnapshot([fixture({ events }), fixture({ id: "other" })], async (path) => {
    const store = new DurableTaskStore(path, { maxEvents: 2, debounceMs: 0 });
    expect(store.get("task-1")?.events).toEqual(events.slice(-2));
    expect(store.list().find((task) => task.id === "task-1")?.events).toEqual(events.slice(-2));
    store.remove("other");
    await store.flush();
    expect(JSON.parse(await readFile(path, "utf8")).tasks[0].events).toEqual(events.slice(-2));
  });
});

const validEvents: AgentEvent[] = [
  { kind: "meta", model: "model", providerSessionId: "provider-session" },
  { kind: "options", options: [
    { id: "model", label: "Model", kind: "select", value: "model", role: "effort",
      choices: [{ value: "model", label: "Model", efforts: [{ value: "high", label: "High" }], defaultEffort: "high" }] },
    { id: "approval", label: "Approval", kind: "toggle", value: true, disabled: false },
  ], actions: { fork: true } },
  { kind: "commands", trigger: "/", commands: [{ name: "compact", description: "Compact", source: "provider" }] },
  ...(["user", "status", "delta", "assistant", "thinking"] as const).map((kind) => ({ kind, text: "text" })),
  { kind: "tool-start", toolId: "tool", name: "Read", detail: "file" },
  { kind: "tool-end", toolId: "tool", name: "Read", detail: "file", ok: true },
  { kind: "done", stats: "done" },
  { kind: "files-changed", files: [{ path: "file", adds: 1, dels: 0, status: "modified" }] },
  { kind: "error", message: "message" },
];

test("recovery preserves valid lifecycle states and every replay event variant", async () => {
  const tasks = ["idle", "running", "exited", "error"].map((status) => fixture({ id: status, status, events: validEvents }));
  await withSnapshot(tasks, (path) => {
    const store = new DurableTaskStore(path);
    for (const status of ["idle", "running", "exited", "error"]) {
      expect(store.get(status)?.status).toBe(status);
      expect(store.get(status)?.events).toEqual(validEvents);
    }
  });
});

const damagedRecords = [
  { status: "unknown" },
  ...[
    { kind: "unknown" }, { kind: "meta", model: 1 },
    { kind: "meta", providerSessionId: false },
    ...["user", "status", "delta", "assistant", "thinking"].map((kind) => ({ kind })),
    { kind: "error", message: null },
    { kind: "tool-start", toolId: "tool" },
    { kind: "tool-end" }, { kind: "tool-end", toolId: "tool", ok: "yes" },
    { kind: "done", stats: {} },
    { kind: "commands", trigger: "!", commands: [] },
    { kind: "commands", trigger: "/", commands: [{}] },
    { kind: "commands", trigger: "/", commands: [{ name: "x", source: 1 }] },
    { kind: "options" }, { kind: "options", options: [{}] },
    ...[
      { kind: "unknown", value: "x" }, { kind: "select", value: 1 },
      { kind: "select", value: "x", role: "unknown" },
      { kind: "select", value: "x", choices: [{ value: "x" }] },
      { kind: "select", value: "x", choices: [{ value: "x", label: "X", efforts: [{}] }] },
    ].map((option) => ({ kind: "options", options: [{ id: "x", label: "X", ...option }] })),
    { kind: "options", options: [], actions: { fork: "yes" } },
    { kind: "files-changed", files: [{}] },
    { kind: "files-changed", files: [{ path: "file", adds: "1", dels: 0, status: "modified" }] },
    null,
  ].map((event) => ({ events: [event] })),
];

test.each(damagedRecords)("recovery skips damaged records while retaining valid neighbors: %j", async (damage) => {
  await withSnapshot([fixture({ id: "damaged", ...damage }), fixture()], (path) => {
    const store = new DurableTaskStore(path);
    expect(store.list().map((task) => task.id)).toEqual(["task-1"]);
  });
});
