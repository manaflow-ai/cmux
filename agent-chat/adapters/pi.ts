import type { Adapter, CommandEntry, OptionChoice, OptionValue, SessionCtx, SessionOption } from "../types";
import { readLines, tryParse, truncate } from "./lines";

const THINKING_CHOICES: OptionChoice[] = ["off", "minimal", "low", "medium", "high", "xhigh"]
  .map((value) => ({ value, label: value }));

interface PiState {
  proc?: Bun.Subprocess<"pipe", "pipe", "pipe">;
  nextId: number;
  pending: Map<number, { resolve: (v: any) => void; reject: (e: Error) => void; timer: ReturnType<typeof setTimeout> }>;
  model: string;
  modelChoices: OptionChoice[];
  thinking: string;
  commands: CommandEntry[];
  initialApplied: boolean;
}

export const piAdapter: Adapter = {
  capabilities: {
    triggers: ["/"],
    options: [
      { id: "model", label: "Model", kind: "select", value: "", disabled: true, description: "Loads at start" },
      { id: "thinking", label: "Thinking", kind: "select", value: "off", choices: THINKING_CHOICES },
    ],
  },
  async send(sess, prompt) {
    const proc = ensureProc(sess);
    await applyInitialOptions(sess);
    proc.stdin.write(JSON.stringify({ type: sess.status === "running" ? "steer" : "prompt", message: prompt }) + "\n");
    proc.stdin.flush();
    sess.setStatus("running");
  },
  stop(sess) {
    const proc = state(sess).proc;
    if (proc) {
      proc.stdin.write(JSON.stringify({ type: "abort" }) + "\n");
      proc.stdin.flush();
    }
  },
  dispose(sess) {
    const st = state(sess);
    const proc = st.proc;
    st.proc = undefined;
    rejectPending(st, "pi process disposed");
    proc?.kill();
  },
  async setOption(sess, id, value) {
    await setPiOption(sess, id, value);
  },
  async refreshOptions(sess) {
    await refreshPi(sess);
  },
  async listOptions(cwd) {
    const models = await fetchPiModels(cwd);
    return buildOptions({
      model: models[0]?.value ?? "",
      modelChoices: models,
      thinking: "off",
    });
  },
  async listCommands(cwd) {
    return [{ trigger: "/", commands: await fetchPiCommands(cwd) }];
  },
};

function state(sess: SessionCtx): PiState {
  let st = sess.internal.pi as PiState | undefined;
  if (!st) {
    st = {
      nextId: 1,
      pending: new Map(),
      model: typeof sess.startOptions.model === "string" ? sess.startOptions.model : "",
      modelChoices: [],
      thinking: typeof sess.startOptions.thinking === "string" ? sess.startOptions.thinking : "off",
      commands: [],
      initialApplied: false,
    };
    sess.internal.pi = st;
  }
  return st;
}

function ensureProc(sess: SessionCtx): Bun.Subprocess<"pipe", "pipe", "pipe"> {
  const st = state(sess);
  if (st.proc && st.proc.exitCode === null && !st.proc.killed) return st.proc;

  const proc = Bun.spawn(["pi", "--mode", "rpc"], {
    cwd: sess.cwd,
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
    env: { ...process.env },
  });
  st.proc = proc;

  readLines(proc.stdout, (line) => handleLine(sess, line), () => {
    if (st.proc === proc) {
      st.proc = undefined;
      rejectPending(st, "pi process exited");
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

function request(sess: SessionCtx, msg: Record<string, unknown>): Promise<any> {
  const st = state(sess);
  const proc = ensureProc(sess);
  const id = st.nextId++;
  const payload = { id, ...msg };
  const promise = new Promise<any>((resolve, reject) => {
    const timer = setTimeout(() => {
      st.pending.delete(id);
      reject(new Error(`pi ${msg.type} timed out`));
    }, 12_000);
    st.pending.set(id, { resolve, reject, timer });
  });
  proc.stdin.write(JSON.stringify(payload) + "\n");
  proc.stdin.flush();
  return promise;
}

function rejectPending(st: PiState, message: string) {
  for (const p of st.pending.values()) {
    clearTimeout(p.timer);
    p.reject(new Error(message));
  }
  st.pending.clear();
}

async function applyInitialOptions(sess: SessionCtx) {
  const st = state(sess);
  if (st.initialApplied) return;
  st.initialApplied = true;
  if (typeof sess.startOptions.model === "string") await setPiOption(sess, "model", st.model);
  if (typeof sess.startOptions.thinking === "string") await setPiOption(sess, "thinking", st.thinking);
  if (!st.modelChoices.length || !st.commands.length) await refreshPi(sess);
}

async function setPiOption(sess: SessionCtx, id: string, value: OptionValue) {
  const st = state(sess);
  switch (id) {
    case "model": {
      if (typeof value !== "string") throw new Error("model must be a string");
      const slash = value.indexOf("/");
      if (slash <= 0) throw new Error(`invalid pi model: ${value}`);
      const provider = value.slice(0, slash);
      const modelId = value.slice(slash + 1);
      await request(sess, { type: "set_model", provider, modelId });
      st.model = value;
      break;
    }
    case "thinking":
      if (typeof value !== "string") throw new Error("thinking must be a string");
      await request(sess, { type: "set_thinking_level", level: value });
      st.thinking = value;
      break;
    default:
      throw new Error(`unsupported pi option: ${id}`);
  }
  emitOptions(sess);
}

async function refreshPi(sess: SessionCtx) {
  const st = state(sess);
  const models = await request(sess, { type: "get_available_models" });
  st.modelChoices = normalizeModels(models?.models ?? models?.data?.models);
  if (!st.model) st.model = st.modelChoices[0]?.value ?? "";
  emitOptions(sess);
  const commands = await request(sess, { type: "get_commands" });
  st.commands = normalizeCommands(commands?.commands ?? commands?.data?.commands);
  sess.emit({ kind: "commands", trigger: "/", commands: st.commands });
}

function emitOptions(sess: SessionCtx) {
  sess.emit({ kind: "options", options: buildOptions(state(sess)) });
}

function buildOptions(st: Pick<PiState, "model" | "modelChoices" | "thinking">): SessionOption[] {
  return [
    { id: "model", label: "Model", kind: "select", value: st.model, choices: st.modelChoices, disabled: !st.modelChoices.length },
    { id: "thinking", label: "Thinking", kind: "select", value: st.thinking, choices: THINKING_CHOICES },
  ];
}

function handleLine(sess: SessionCtx, line: string) {
  const ev = tryParse(line);
  if (!ev) return;
  if (ev.type === "response" && ev.id != null) {
    const st = state(sess);
    const p = st.pending.get(ev.id);
    if (p) {
      st.pending.delete(ev.id);
      clearTimeout(p.timer);
      ev.success === false ? p.reject(new Error(ev.error ?? `${ev.command ?? "request"} failed`)) : p.resolve(ev.data ?? ev);
    }
    return;
  }
  switch (ev.type) {
    case "message_start":
      if (ev.message?.role === "assistant" && ev.message?.model && !sess.internal.metaSent) {
        sess.internal.metaSent = true;
        const value = `${ev.message.provider}/${ev.message.model}`;
        state(sess).model = value;
        sess.emit({ kind: "meta", model: value });
        emitOptions(sess);
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

function normalizeModels(models: any): OptionChoice[] {
  if (!Array.isArray(models)) return [];
  return models.map((m) => ({
    value: `${m.provider}/${m.id}`,
    label: String(m.name ?? `${m.provider}/${m.id}`),
    description: m.reasoning ? "supports thinking" : undefined,
  }));
}

function normalizeCommands(commands: any): CommandEntry[] {
  if (!Array.isArray(commands)) return [];
  return commands.map((c) => ({
    name: String(c.name ?? "").replace(/^\/+/, ""),
    description: c.description ? String(c.description) : undefined,
    source: c.source ? String(c.source) : undefined,
  })).filter((c) => c.name);
}

async function fetchPiModels(cwd: string): Promise<OptionChoice[]> {
  const res = await withPiRpc(cwd, [{ type: "get_available_models" }]);
  return normalizeModels(res[0]?.models);
}

async function fetchPiCommands(cwd: string): Promise<CommandEntry[]> {
  const res = await withPiRpc(cwd, [{ type: "get_commands" }]);
  return normalizeCommands(res[0]?.commands);
}

async function withPiRpc(cwd: string, requests: Record<string, unknown>[]): Promise<any[]> {
  const proc = Bun.spawn(["pi", "--mode", "rpc"], {
    cwd,
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
    env: { ...process.env, PI_OFFLINE: "1" },
  });
  try {
    return await new Promise<any[]>((resolve, reject) => {
      const out: any[] = [];
      const pending = new Set<number>();
      const timer = setTimeout(() => reject(new Error("pi catalog timed out")), 12_000);
      readLines(proc.stdout, (line) => {
        const ev = tryParse(line);
        if (ev?.type !== "response" || ev.id == null || !pending.has(ev.id)) return;
        pending.delete(ev.id);
        if (ev.success === false) {
          clearTimeout(timer);
          reject(new Error(ev.error ?? "pi catalog request failed"));
          return;
        }
        out.push(ev.data ?? ev);
        if (!pending.size) {
          clearTimeout(timer);
          resolve(out);
        }
      }, () => {
        clearTimeout(timer);
        reject(new Error("pi exited during catalog request"));
      });
      requests.forEach((req, i) => {
        const id = i + 1;
        pending.add(id);
        proc.stdin.write(JSON.stringify({ id, ...req }) + "\n");
      });
      proc.stdin.flush();
    });
  } finally {
    proc.kill();
  }
}

function textOf(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content.map((c: any) => c?.text ?? "").join("");
  }
  return content ? JSON.stringify(content) : "";
}
