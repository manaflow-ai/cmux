import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { DurableTaskStore, type DurableTaskRecord } from "../task-store";

function assert(cond: unknown, message: string): asserts cond {
  if (!cond) throw new Error(message);
}

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
    { kind: "routing", phase: "started", conversationId: "conversation-1", requestId: "request-1", attempt: 1, provider: "codex" },
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
