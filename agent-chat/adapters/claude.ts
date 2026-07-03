import type { Adapter, SessionCtx } from "../types";
import { readLines, tryParse, truncate } from "./lines";

// Claude Code: one persistent `claude -p` process per session, bidirectional
// stream-json. Deltas via stream_event, tools via assistant/user messages,
// turn end via result.
export const claudeAdapter: Adapter = {
  send(sess, prompt) {
    const proc = ensureProc(sess);
    const msg = {
      type: "user",
      message: { role: "user", content: [{ type: "text", text: prompt }] },
    };
    proc.stdin.write(JSON.stringify(msg) + "\n");
    proc.stdin.flush();
    sess.setStatus("running");
  },
  stop(sess) {
    const proc = sess.internal.proc as Bun.Subprocess | undefined;
    if (proc) proc.kill("SIGINT"); // claude treats SIGINT as interrupt-turn... it exits; treat as dispose
  },
  dispose(sess) {
    const proc = sess.internal.proc as Bun.Subprocess | undefined;
    sess.internal.proc = undefined;
    proc?.kill();
  },
};

function ensureProc(sess: SessionCtx): Bun.Subprocess<"pipe", "pipe", "pipe"> {
  let proc = sess.internal.proc as Bun.Subprocess<"pipe", "pipe", "pipe"> | undefined;
  if (proc && proc.exitCode === null && !proc.killed) return proc;

  const args = [
    "-p",
    "--input-format", "stream-json",
    "--output-format", "stream-json",
    "--include-partial-messages",
    "--verbose",
  ];
  // acceptEdits + a broad allowlist rather than bypassPermissions: bypass can
  // stall on its one-time trust confirmation, which never renders in -p mode.
  if (sess.autoApprove) {
    args.push("--permission-mode", "acceptEdits", "--allowedTools", "Bash Read Edit Write Glob Grep WebFetch WebSearch");
  }
  proc = Bun.spawn(["claude", ...args], {
    cwd: sess.cwd,
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
    // Scrub nested-session markers so a server launched from inside a Claude
    // Code session still spawns a normal top-level claude.
    env: { ...process.env, CLAUDECODE: undefined, CLAUDE_CODE_ENTRYPOINT: undefined, CLAUDE_CODE_SSE_PORT: undefined },
  });
  sess.internal.proc = proc;

  readLines(proc.stdout, (line) => handleLine(sess, line), () => {
    if (sess.internal.proc === proc) {
      sess.internal.proc = undefined;
      if (sess.status === "running") {
        sess.emit({ kind: "error", message: "claude process exited mid-turn" });
      }
      sess.setStatus("idle");
    }
  });
  readLines(proc.stderr, (line) => {
    sess.internal.lastStderr = line;
  });
  proc.exited.then((code) => {
    if (code !== 0 && sess.internal.proc === proc) {
      const err = sess.internal.lastStderr as string | undefined;
      sess.emit({ kind: "error", message: `claude exited (${code})${err ? ": " + truncate(err) : ""}` });
      sess.internal.proc = undefined;
      sess.setStatus("idle");
    }
  });
  return proc;
}

function handleLine(sess: SessionCtx, line: string) {
  const ev = tryParse(line);
  if (!ev) return;
  switch (ev.type) {
    case "system":
      if (ev.subtype === "init") {
        sess.emit({ kind: "meta", model: ev.model, providerSessionId: ev.session_id });
      }
      break;
    case "stream_event": {
      const e = ev.event;
      if (e?.type === "content_block_delta") {
        if (e.delta?.type === "text_delta" && e.delta.text) {
          sess.emit({ kind: "delta", text: e.delta.text });
        } else if (e.delta?.type === "thinking_delta" && e.delta.thinking) {
          sess.emit({ kind: "thinking", text: e.delta.thinking });
        }
      }
      break;
    }
    case "assistant": {
      for (const block of ev.message?.content ?? []) {
        if (block.type === "tool_use") {
          sess.emit({
            kind: "tool-start",
            toolId: block.id,
            name: block.name,
            detail: truncate(JSON.stringify(block.input ?? {})),
          });
        }
      }
      break;
    }
    case "user": {
      for (const block of ev.message?.content ?? []) {
        if (block.type === "tool_result") {
          const content = typeof block.content === "string"
            ? block.content
            : (block.content ?? []).map((c: any) => c.text ?? "").join("");
          sess.emit({
            kind: "tool-end",
            toolId: block.tool_use_id,
            ok: !block.is_error,
            detail: truncate(content, 400),
          });
        }
      }
      break;
    }
    case "result": {
      const stats = [
        ev.total_cost_usd != null ? `$${ev.total_cost_usd.toFixed(3)}` : null,
        ev.duration_ms != null ? `${(ev.duration_ms / 1000).toFixed(1)}s` : null,
        ev.num_turns != null ? `${ev.num_turns} turn${ev.num_turns === 1 ? "" : "s"}` : null,
      ].filter(Boolean).join(" · ");
      if (ev.is_error) {
        sess.emit({ kind: "error", message: truncate(String(ev.result ?? ev.subtype), 400) });
      }
      sess.emit({ kind: "done", stats });
      sess.setStatus("idle");
      break;
    }
  }
}
