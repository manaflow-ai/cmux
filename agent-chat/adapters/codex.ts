import type { Adapter, SessionCtx } from "../types";
import { readLines, tryParse, truncate } from "./lines";

// Codex: one shared `codex app-server` process (JSON-RPC over NDJSON stdio,
// the same interface the codex IDE extension uses) hosts a thread per chat
// session. Streaming comes from item/agentMessage/delta notifications; turn
// lifecycle from turn/started / turn/completed / turn/failed.

interface AppServer {
  proc: Bun.Subprocess<"pipe", "pipe", "pipe">;
  request(method: string, params?: unknown): Promise<any>;
  write(msg: unknown): void;
  sessionsByThread: Map<string, SessionCtx>;
}

let shared: AppServer | null = null;
let sharedStarting: Promise<AppServer> | null = null;

async function ensureServer(): Promise<AppServer> {
  if (shared && shared.proc.exitCode === null && !shared.proc.killed) return shared;
  if (sharedStarting) return sharedStarting;
  sharedStarting = startServer().finally(() => {
    sharedStarting = null;
  });
  return sharedStarting;
}

async function startServer(): Promise<AppServer> {
  const proc = Bun.spawn(["codex", "app-server"], {
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
    env: { ...process.env },
  });
  let nextId = 1;
  const pending = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void }>();
  const write = (msg: unknown) => {
    proc.stdin.write(JSON.stringify(msg) + "\n");
    proc.stdin.flush();
  };
  const request = (method: string, params?: unknown) =>
    new Promise<any>((resolve, reject) => {
      const id = nextId++;
      pending.set(id, { resolve, reject });
      write({ jsonrpc: "2.0", id, method, params: params ?? {} });
    });
  const srv: AppServer = { proc, request, write, sessionsByThread: new Map() };

  readLines(proc.stdout, (line) => {
    const msg = tryParse(line);
    if (!msg) return;
    if (msg.id != null && (msg.result !== undefined || msg.error !== undefined)) {
      const p = pending.get(msg.id);
      if (p) {
        pending.delete(msg.id);
        msg.error ? p.reject(new Error(msg.error.message ?? "codex error")) : p.resolve(msg.result);
      }
      return;
    }
    handleServerMessage(srv, msg);
  }, () => {
    for (const p of pending.values()) p.reject(new Error("codex app-server exited"));
    pending.clear();
    for (const sess of srv.sessionsByThread.values()) {
      if (sess.status === "running") {
        sess.emit({ kind: "error", message: "codex app-server exited mid-turn" });
        sess.emit({ kind: "done" });
        sess.setStatus("idle");
      }
      sess.internal.threadId = undefined;
    }
    if (shared === srv) shared = null;
  });
  readLines(proc.stderr, () => {});

  await request("initialize", { clientInfo: { name: "cmux", title: "cmux", version: "0.1" } });
  shared = srv;
  return srv;
}

function handleServerMessage(srv: AppServer, msg: any) {
  const p = msg.params ?? {};
  const sess = p.threadId ? srv.sessionsByThread.get(p.threadId) : undefined;

  // Server -> client request (approvals such as command execution / patches).
  if (msg.id != null && msg.method) {
    const approve = sess ? sess.autoApprove : false;
    srv.write({ jsonrpc: "2.0", id: msg.id, result: { decision: approve ? "approved" : "denied" } });
    if (sess && !approve) {
      sess.emit({ kind: "status", text: `denied: ${truncate(String(p.command ?? msg.method), 120)} (auto-approve is off)` });
    }
    return;
  }
  if (!sess) return;

  switch (msg.method) {
    case "item/agentMessage/delta":
      if (p.delta) {
        (sess.internal.deltaItems as Set<string>).add(p.itemId);
        sess.emit({ kind: "delta", text: p.delta });
      }
      break;
    case "item/reasoning/delta":
    case "item/reasoningSummary/delta":
      if (p.delta) sess.emit({ kind: "thinking", text: p.delta });
      break;
    case "item/started":
      itemStarted(sess, p.item);
      break;
    case "item/completed":
      itemCompleted(sess, p.item);
      break;
    case "thread/tokenUsage/updated":
      sess.internal.lastUsage = p.tokenUsage?.total;
      break;
    case "turn/completed": {
      const u = sess.internal.lastUsage as any;
      const secs = p.turn?.durationMs != null ? `${(p.turn.durationMs / 1000).toFixed(1)}s` : null;
      const stats = [
        u ? `${u.inputTokens ?? 0} in · ${u.outputTokens ?? 0} out` : null,
        secs,
      ].filter(Boolean).join(" · ");
      sess.emit({ kind: "done", stats });
      sess.setStatus("idle");
      break;
    }
    case "turn/failed": {
      sess.emit({ kind: "error", message: truncate(p.error?.message ?? p.turn?.error?.message ?? "turn failed", 400) });
      sess.emit({ kind: "done" });
      sess.setStatus("idle");
      break;
    }
  }
}

function itemStarted(sess: SessionCtx, item: any) {
  if (!item) return;
  switch (item.type) {
    case "commandExecution":
      sess.emit({ kind: "tool-start", toolId: item.id, name: "shell", detail: truncate(item.command ?? "") });
      break;
    case "fileChange":
    case "patchApply":
      sess.emit({ kind: "tool-start", toolId: item.id, name: "edit", detail: truncate(summarizeChanges(item)) });
      break;
    case "webSearch":
      sess.emit({ kind: "tool-start", toolId: item.id, name: "web_search", detail: truncate(item.query ?? "") });
      break;
    case "mcpToolCall":
      sess.emit({ kind: "tool-start", toolId: item.id, name: item.tool ?? "mcp", detail: truncate(JSON.stringify(item.arguments ?? {})) });
      break;
  }
}

function itemCompleted(sess: SessionCtx, item: any) {
  if (!item) return;
  switch (item.type) {
    case "agentMessage": {
      // Streaming already delivered deltas for this item; only emit the full
      // text when no delta arrived (e.g. replayed items).
      const seen = sess.internal.deltaItems as Set<string>;
      if (item.text && !seen.has(item.id)) sess.emit({ kind: "assistant", text: item.text });
      seen.delete(item.id);
      break;
    }
    case "commandExecution":
      sess.emit({
        kind: "tool-end",
        toolId: item.id,
        name: "shell",
        ok: item.status !== "failed" && (item.exitCode == null || item.exitCode === 0),
        detail: truncate(item.aggregatedOutput ?? "", 400),
      });
      break;
    case "fileChange":
    case "patchApply":
      sess.emit({ kind: "tool-end", toolId: item.id, name: "edit", ok: item.status !== "failed", detail: truncate(summarizeChanges(item)) });
      break;
    case "webSearch":
    case "mcpToolCall":
      sess.emit({ kind: "tool-end", toolId: item.id, ok: item.status !== "failed" });
      break;
  }
}

function summarizeChanges(item: any): string {
  const changes = item.changes ?? [];
  if (Array.isArray(changes) && changes.length) {
    return changes.map((c: any) => `${c.kind ?? "edit"} ${c.path ?? ""}`).join(", ");
  }
  return item.status ?? "file change";
}

export const codexAdapter: Adapter = {
  async send(sess, prompt) {
    sess.setStatus("running");
    try {
      const srv = await ensureServer();
      sess.internal.deltaItems ??= new Set<string>();
      let threadId = sess.internal.threadId as string | undefined;
      if (!threadId) {
        const res = await srv.request("thread/start", { cwd: sess.cwd });
        threadId = res.thread?.id;
        if (!threadId) throw new Error("codex thread/start returned no thread id");
        sess.internal.threadId = threadId;
        srv.sessionsByThread.set(threadId, sess);
        sess.emit({ kind: "meta", providerSessionId: threadId });
      }
      await srv.request("turn/start", {
        threadId,
        input: [{ type: "text", text: prompt }],
      });
      // Completion arrives via the turn/completed notification.
    } catch (err) {
      sess.emit({ kind: "error", message: truncate(String(err), 400) });
      sess.emit({ kind: "done" });
      sess.setStatus("idle");
    }
  },
  stop(sess) {
    const threadId = sess.internal.threadId as string | undefined;
    if (threadId && shared) {
      shared.request("turn/interrupt", { threadId }).catch(() => {});
    }
  },
  dispose(sess) {
    const threadId = sess.internal.threadId as string | undefined;
    if (threadId && shared) shared.sessionsByThread.delete(threadId);
  },
};
