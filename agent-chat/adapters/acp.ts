import type { Adapter, SessionCtx, ProviderDef } from "../types";
import { readLines, tryParse, truncate } from "./lines";

// Generic Agent Client Protocol (https://agentclientprotocol.com) client over
// stdio NDJSON JSON-RPC. One adapter covers every ACP-speaking agent:
// `opencode acp`, `gemini --experimental-acp`, `claude-code-acp`, goose, ...
export function makeAcpAdapter(def: ProviderDef): Adapter {
  return {
    async send(sess, prompt) {
      sess.setStatus("running");
      try {
        const st = await ensureAcp(sess, def);
        const res = await st.request("session/prompt", {
          sessionId: st.acpSessionId,
          prompt: [{ type: "text", text: prompt }],
        });
        sess.emit({ kind: "done", stats: res?.stopReason ? `stop: ${res.stopReason}` : undefined });
      } catch (err) {
        sess.emit({ kind: "error", message: truncate(String(err), 400) });
        sess.emit({ kind: "done" });
      }
      sess.setStatus("idle");
    },
    stop(sess) {
      const st = sess.internal.acp as AcpState | undefined;
      if (st?.acpSessionId) {
        st.notify("session/cancel", { sessionId: st.acpSessionId });
      }
    },
    dispose(sess) {
      const st = sess.internal.acp as AcpState | undefined;
      sess.internal.acp = undefined;
      st?.proc.kill();
    },
  };
}

interface AcpState {
  proc: Bun.Subprocess<"pipe", "pipe", "pipe">;
  acpSessionId: string;
  request(method: string, params: unknown): Promise<any>;
  notify(method: string, params: unknown): void;
}

async function ensureAcp(sess: SessionCtx, def: ProviderDef): Promise<AcpState> {
  const existing = sess.internal.acp as AcpState | undefined;
  if (existing && existing.proc.exitCode === null && !existing.proc.killed) return existing;

  const cmd = [...(def.cmd ?? [])];
  if (sess.autoApprove && def.autoApproveArgs) cmd.push(...def.autoApproveArgs);
  const proc = Bun.spawn(cmd, {
    cwd: sess.cwd,
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
    env: { ...process.env },
  });

  let nextId = 1;
  const pending = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void }>();
  const writeMsg = (msg: unknown) => {
    proc.stdin.write(JSON.stringify(msg) + "\n");
    proc.stdin.flush();
  };
  const request = (method: string, params: unknown) =>
    new Promise<any>((resolve, reject) => {
      const id = nextId++;
      pending.set(id, { resolve, reject });
      writeMsg({ jsonrpc: "2.0", id, method, params });
    });
  const notify = (method: string, params: unknown) =>
    writeMsg({ jsonrpc: "2.0", method, params });

  readLines(proc.stdout, (line) => {
    const msg = tryParse(line);
    if (!msg) return;
    if (msg.id != null && (msg.result !== undefined || msg.error !== undefined)) {
      const p = pending.get(msg.id);
      if (p) {
        pending.delete(msg.id);
        msg.error ? p.reject(new Error(msg.error.message ?? "acp error")) : p.resolve(msg.result);
      }
      return;
    }
    if (msg.method) handleAgentMessage(sess, msg, writeMsg);
  }, () => {
    for (const p of pending.values()) p.reject(new Error(`${def.id} acp process exited`));
    pending.clear();
    if (sess.internal.acp && (sess.internal.acp as AcpState).proc === proc) {
      sess.internal.acp = undefined;
    }
  });
  readLines(proc.stderr, () => {});

  await request("initialize", {
    protocolVersion: 1,
    clientCapabilities: { fs: { readTextFile: false, writeTextFile: false } },
  });
  const created = await request("session/new", { cwd: sess.cwd, mcpServers: [] });
  const st: AcpState = { proc, acpSessionId: created.sessionId, request, notify };
  sess.internal.acp = st;
  sess.emit({ kind: "meta", providerSessionId: created.sessionId });
  return st;
}

// Notifications and reverse requests from the agent.
function handleAgentMessage(sess: SessionCtx, msg: any, writeMsg: (m: unknown) => void) {
  if (msg.method === "session/update") {
    const u = msg.params?.update;
    if (!u) return;
    switch (u.sessionUpdate) {
      case "agent_message_chunk":
        if (u.content?.text) sess.emit({ kind: "delta", text: u.content.text });
        break;
      case "agent_thought_chunk":
        if (u.content?.text) sess.emit({ kind: "thinking", text: u.content.text });
        break;
      case "tool_call":
        sess.emit({
          kind: "tool-start",
          toolId: u.toolCallId,
          name: u.title ?? u.kind ?? "tool",
          detail: truncate(JSON.stringify(u.rawInput ?? {})),
        });
        break;
      case "tool_call_update":
        if (u.status === "completed" || u.status === "failed") {
          sess.emit({
            kind: "tool-end",
            toolId: u.toolCallId,
            ok: u.status === "completed",
            detail: truncate(contentText(u.content), 400),
          });
        }
        break;
      case "plan":
        sess.emit({
          kind: "status",
          text: "plan: " + (u.entries ?? []).map((e: any) => e.content).join(" → ").slice(0, 300),
        });
        break;
    }
    return;
  }
  // Reverse request: must answer or the agent hangs.
  if (msg.id != null && msg.method === "session/request_permission") {
    const options: any[] = msg.params?.options ?? [];
    const allow = options.find((o) => o.kind === "allow_always")
      ?? options.find((o) => o.kind === "allow_once");
    const reject = options.find((o) => o.kind?.startsWith("reject")) ?? options[0];
    const choice = sess.autoApprove && allow ? allow : reject;
    if (choice !== allow) {
      const tc = msg.params?.toolCall;
      sess.emit({ kind: "status", text: `denied: ${truncate(tc?.title ?? "tool", 120)} (auto-approve is off)` });
    }
    writeMsg({
      jsonrpc: "2.0",
      id: msg.id,
      result: { outcome: { outcome: "selected", optionId: choice?.optionId } },
    });
    return;
  }
  if (msg.id != null) {
    writeMsg({ jsonrpc: "2.0", id: msg.id, error: { code: -32601, message: "method not supported by cmux-agent-ui" } });
  }
}

function contentText(content: unknown): string {
  if (!Array.isArray(content)) return "";
  return content
    .map((c: any) => c?.content?.text ?? c?.text ?? "")
    .join("");
}
