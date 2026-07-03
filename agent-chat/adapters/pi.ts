import type { Adapter, SessionCtx } from "../types";
import { readLines, tryParse, truncate } from "./lines";

// pi: one persistent `pi --mode rpc` process per session. Prompts go in as
// {"type":"prompt"}, streaming comes back as message_update events wrapping
// assistantMessageEvent deltas; agent_end closes the agent loop.
export const piAdapter: Adapter = {
  send(sess, prompt) {
    const proc = ensureProc(sess);
    proc.stdin.write(JSON.stringify({ type: "prompt", message: prompt }) + "\n");
    proc.stdin.flush();
    sess.setStatus("running");
  },
  stop(sess) {
    const proc = sess.internal.proc as Bun.Subprocess<"pipe"> | undefined;
    if (proc) {
      proc.stdin.write(JSON.stringify({ type: "abort" }) + "\n");
      proc.stdin.flush();
    }
  },
  dispose(sess) {
    (sess.internal.proc as Bun.Subprocess | undefined)?.kill();
    sess.internal.proc = undefined;
  },
};

function ensureProc(sess: SessionCtx): Bun.Subprocess<"pipe", "pipe", "pipe"> {
  let proc = sess.internal.proc as Bun.Subprocess<"pipe", "pipe", "pipe"> | undefined;
  if (proc && proc.exitCode === null && !proc.killed) return proc;

  proc = Bun.spawn(["pi", "--mode", "rpc"], {
    cwd: sess.cwd,
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
    env: { ...process.env },
  });
  sess.internal.proc = proc;

  readLines(proc.stdout, (line) => handleLine(sess, line), () => {
    if (sess.internal.proc === proc) {
      sess.internal.proc = undefined;
      if (sess.status === "running") {
        sess.emit({ kind: "error", message: "pi process exited mid-turn" });
        sess.emit({ kind: "done" });
      }
      sess.setStatus("idle");
    }
  });
  readLines(proc.stderr, (line) => { sess.internal.lastStderr = line; });
  return proc;
}

function handleLine(sess: SessionCtx, line: string) {
  const ev = tryParse(line);
  if (!ev) return;
  switch (ev.type) {
    case "message_start":
      if (ev.message?.role === "assistant" && ev.message?.model && !sess.internal.metaSent) {
        sess.internal.metaSent = true;
        sess.emit({ kind: "meta", model: `${ev.message.provider}/${ev.message.model}` });
      }
      break;
    case "message_update": {
      const e = ev.assistantMessageEvent;
      if (!e) break;
      if (e.type === "text_delta" && e.delta) sess.emit({ kind: "delta", text: e.delta });
      else if (e.type === "thinking_delta" && e.delta) sess.emit({ kind: "thinking", text: e.delta });
      break;
    }
    case "message_end": {
      // Tool calls appear as content blocks on the finished assistant message.
      const msg = ev.message;
      if (msg?.role === "assistant") {
        const err = msg.errorMessage ?? (msg.stopReason === "error" ? "provider error" : null);
        if (err) sess.emit({ kind: "error", message: truncate(String(err), 400) });
        for (const block of msg.content ?? []) {
          if (block.type === "toolCall") {
            sess.emit({
              kind: "tool-start",
              toolId: block.id ?? block.name,
              name: block.name ?? "tool",
              detail: truncate(JSON.stringify(block.arguments ?? {})),
            });
          }
        }
      }
      if (msg?.role === "toolResult") {
        sess.emit({
          kind: "tool-end",
          toolId: msg.toolCallId ?? "tool",
          ok: !msg.isError,
          detail: truncate(textOf(msg.content), 400),
        });
      }
      break;
    }
    case "tool_execution_start":
      sess.emit({
        kind: "tool-start",
        toolId: ev.toolCallId ?? ev.toolName ?? "tool",
        name: ev.toolName ?? "tool",
        detail: truncate(JSON.stringify(ev.args ?? {})),
      });
      break;
    case "tool_execution_end":
      sess.emit({
        kind: "tool-end",
        toolId: ev.toolCallId ?? ev.toolName ?? "tool",
        name: ev.toolName,
        ok: !ev.isError,
        detail: truncate(textOf(ev.result?.content ?? ev.result), 400),
      });
      break;
    case "agent_end":
      sess.emit({ kind: "done" });
      sess.setStatus("idle");
      break;
    case "error":
      sess.emit({ kind: "error", message: truncate(ev.message ?? JSON.stringify(ev), 400) });
      break;
  }
}

function textOf(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content.map((c: any) => c?.text ?? "").join("");
  }
  return content ? JSON.stringify(content) : "";
}
