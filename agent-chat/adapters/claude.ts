import type { Adapter, CommandEntry, OptionChoice, OptionValue, SessionCtx, SessionOption } from "../types";
import { readLines, tryParse, truncate } from "./lines";

const PERMISSION_CHOICES: OptionChoice[] = [
  { value: "default", label: "Default" },
  { value: "acceptEdits", label: "Accept edits" },
  { value: "plan", label: "Plan" },
  { value: "bypassPermissions", label: "Bypass" },
  { value: "dontAsk", label: "Don't ask" },
  { value: "auto", label: "Auto" },
];
const THINKING_CHOICES: OptionChoice[] = [
  { value: "0", label: "Thinking off" },
  { value: "4096", label: "4k thinking" },
  { value: "16384", label: "16k thinking" },
  { value: "32768", label: "32k thinking" },
];
const EFFORT_CHOICES: OptionChoice[] = ["low", "medium", "high", "xhigh", "max"]
  .map((value) => ({ value, label: value }));
const CONTEXT_CHOICES: OptionChoice[] = [
  { value: "200k", label: "200k" },
  { value: "1M", label: "1M" },
];
const DEFAULT_MODEL: OptionChoice = { value: "default", label: "Default" };
interface ClaudeModelMeta {
  efforts: OptionChoice[];
  supportsFastMode: boolean;
  context?: { base: string; extended: string };
}

interface ClaudeState {
  proc?: Bun.Subprocess<"pipe", "pipe", "pipe">;
  nextRequest: number;
  pending: Map<string, { resolve: (v: any) => void; reject: (e: Error) => void; timer: ReturnType<typeof setTimeout> }>;
  model: string;
  modelChoices: OptionChoice[];
  modelMeta: Map<string, ClaudeModelMeta>;
  permissionMode: string;
  thinking: string;
  effort: string;
  fastMode: boolean;
  context: string;
  initialApplied: boolean;
  commands: CommandEntry[];
}

export const claudeAdapter: Adapter = {
  capabilities: {
    triggers: ["/"],
    options: [
      { id: "model", label: "Model", kind: "select", value: "default", choices: [DEFAULT_MODEL], disabled: true, description: "Loads at start" },
      { id: "permissionMode", label: "Mode", kind: "select", value: "acceptEdits", choices: PERMISSION_CHOICES },
      { id: "thinking", label: "Thinking", kind: "select", value: "0", role: "thinking-budget", choices: THINKING_CHOICES },
      { id: "effort", label: "Effort", kind: "select", value: "medium", role: "effort", choices: EFFORT_CHOICES },
      { id: "fastMode", label: "Fast", kind: "toggle", value: false },
    ],
  },
  async send(sess, prompt) {
    const proc = ensureProc(sess);
    await applyInitialOptions(sess);
    const msg = {
      type: "user",
      message: { role: "user", content: [{ type: "text", text: prompt }] },
    };
    proc.stdin.write(JSON.stringify(msg) + "\n");
    proc.stdin.flush();
    sess.setStatus("running");
  },
  stop(sess) {
    const proc = state(sess).proc;
    if (!proc || proc.exitCode !== null || proc.killed) return;
    control(sess, "interrupt").catch((err) => {
      sess.emit({ kind: "error", message: truncate(String(err), 200) });
    });
  },
  dispose(sess) {
    const st = state(sess);
    const proc = st.proc;
    st.proc = undefined;
    for (const p of st.pending.values()) {
      clearTimeout(p.timer);
      p.reject(new Error("claude process disposed"));
    }
    st.pending.clear();
    proc?.kill();
  },
  async setOption(sess, id, value) {
    await setClaudeOption(sess, id, value);
  },
  async refreshOptions(sess) {
    await refreshClaudeOptions(sess);
  },
  async listOptions(cwd) {
      const choices = await fetchClaudeModels(cwd);
    const st = {
      model: "default",
      modelChoices: choices.choices,
      modelMeta: choices.meta,
      permissionMode: "acceptEdits",
      thinking: "0",
      effort: "medium",
      fastMode: false,
      context: "200k",
    };
    normalizeEffort(st);
    return buildOptions(st);
  },
  async forkSession(source, target) {
    const providerSessionId = source.internal.providerSessionId as string | undefined;
    if (!providerSessionId) throw new Error("claude session id is not available yet");
    target.internal.claudeFork = { providerSessionId };
  },
};

function state(sess: SessionCtx): ClaudeState {
  let st = sess.internal.claude as ClaudeState | undefined;
  if (!st) {
    st = {
      nextRequest: 1,
      pending: new Map(),
      model: stringOption(sess, "model", "default"),
      modelChoices: [DEFAULT_MODEL],
      modelMeta: new Map([["default", { efforts: EFFORT_CHOICES, supportsFastMode: true }]]),
      permissionMode: stringOption(sess, "permissionMode", sess.autoApprove ? "acceptEdits" : "default"),
      thinking: stringOption(sess, "thinking", "0"),
      effort: stringOption(sess, "effort", "medium"),
      fastMode: booleanOption(sess, "fastMode", false),
      context: stringOption(sess, "context", "200k"),
      initialApplied: false,
      commands: [],
    };
    sess.internal.claude = st;
  }
  return st;
}

function stringOption(sess: SessionCtx, id: string, fallback: string): string {
  const v = sess.startOptions[id];
  return typeof v === "string" ? v : fallback;
}

function booleanOption(sess: SessionCtx, id: string, fallback: boolean): boolean {
  const v = sess.startOptions[id];
  return typeof v === "boolean" ? v : fallback;
}

function ensureProc(sess: SessionCtx): Bun.Subprocess<"pipe", "pipe", "pipe"> {
  const st = state(sess);
  if (st.proc && st.proc.exitCode === null && !st.proc.killed) return st.proc;

  const args = [
    "-p",
    "--input-format", "stream-json",
    "--output-format", "stream-json",
    "--include-partial-messages",
    "--verbose",
  ];
  const apiModel = resolveClaudeModelId(st);
  if (apiModel !== "default") args.push("--model", apiModel);
  const fork = sess.internal.claudeFork as { providerSessionId?: string } | undefined;
  if (fork?.providerSessionId) args.push("--resume", fork.providerSessionId, "--fork-session");
  if (st.permissionMode !== "default") args.push("--permission-mode", st.permissionMode);
  if (sess.autoApprove) args.push("--allowedTools", "Bash Read Edit Write Glob Grep WebFetch WebSearch");
  if (typeof sess.startOptions.effort === "string") args.push("--effort", st.effort);

  const proc = Bun.spawn(["claude", ...args], {
    cwd: sess.cwd,
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
    env: { ...process.env, CLAUDECODE: undefined, CLAUDE_CODE_ENTRYPOINT: undefined, CLAUDE_CODE_SSE_PORT: undefined },
  });
  st.proc = proc;

  readLines(proc.stdout, (line) => handleLine(sess, line), () => {
    if (st.proc === proc) {
      st.proc = undefined;
      rejectPending(st, "claude process exited");
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
    if (code !== 0 && st.proc === proc) {
      const err = sess.internal.lastStderr as string | undefined;
      sess.emit({ kind: "error", message: `claude exited (${code})${err ? ": " + truncate(err) : ""}` });
      st.proc = undefined;
      rejectPending(st, `claude exited (${code})`);
      sess.setStatus("idle");
    }
  });
  return proc;
}

function rejectPending(st: ClaudeState, message: string) {
  for (const p of st.pending.values()) {
    clearTimeout(p.timer);
    p.reject(new Error(message));
  }
  st.pending.clear();
}

function control(sess: SessionCtx, subtype: string, request: Record<string, unknown> = {}): Promise<any> {
  const st = state(sess);
  const proc = ensureProc(sess);
  const request_id = `cmux-${st.nextRequest++}`;
  const payload = { type: "control_request", request_id, request: { subtype, ...request } };
  const promise = new Promise<any>((resolve, reject) => {
    const timer = setTimeout(() => {
      st.pending.delete(request_id);
      reject(new Error(`claude ${subtype} timed out`));
    }, 12_000);
    st.pending.set(request_id, { resolve, reject, timer });
  });
  proc.stdin.write(JSON.stringify(payload) + "\n");
  proc.stdin.flush();
  return promise.then((response) => {
    if (response?.subtype && response.subtype !== "success") {
      throw new Error(response.error ?? response.message ?? `${subtype} failed`);
    }
    return response?.response;
  });
}

async function applyInitialOptions(sess: SessionCtx) {
  const st = state(sess);
  if (st.initialApplied) return;
  st.initialApplied = true;
  if (typeof sess.startOptions.model === "string" || typeof sess.startOptions.context === "string") {
    const model = resolveClaudeModelId(st);
    await control(sess, "set_model", model === "default" ? {} : { model });
  }
  if (typeof sess.startOptions.permissionMode === "string") await control(sess, "set_permission_mode", { mode: st.permissionMode });
  if (typeof sess.startOptions.thinking === "string") {
    await control(sess, "set_max_thinking_tokens", { max_thinking_tokens: Number(st.thinking) || 0 });
  }
  if (typeof sess.startOptions.effort === "string") {
    await control(sess, "apply_flag_settings", { settings: { effortLevel: st.effort } });
  }
  if (typeof sess.startOptions.fastMode === "boolean") {
    await control(sess, "apply_flag_settings", { settings: { fastMode: st.fastMode } });
  }
  emitOptions(sess);
}

async function setClaudeOption(sess: SessionCtx, id: string, value: OptionValue) {
  const st = state(sess);
  switch (id) {
    case "model": {
      if (typeof value !== "string") throw new Error("model must be a string");
      st.model = value;
      normalizeContext(st);
      const model = resolveClaudeModelId(st);
      await control(sess, "set_model", model === "default" ? {} : { model });
      const changed = normalizeEffort(st);
      if (changed.effort) await control(sess, "apply_flag_settings", { settings: { effortLevel: st.effort } });
      if (changed.fastMode) await control(sess, "apply_flag_settings", { settings: { fastMode: st.fastMode } });
      break;
    }
    case "context": {
      if (typeof value !== "string") throw new Error("context must be a string");
      st.context = value;
      normalizeContext(st);
      const model = resolveClaudeModelId(st);
      await control(sess, "set_model", model === "default" ? {} : { model });
      break;
    }
    case "permissionMode": {
      if (typeof value !== "string") throw new Error("permissionMode must be a string");
      const res = await control(sess, "set_permission_mode", { mode: value });
      st.permissionMode = String(res?.mode ?? value);
      break;
    }
    case "thinking": {
      if (typeof value !== "string") throw new Error("thinking must be a string");
      await control(sess, "set_max_thinking_tokens", { max_thinking_tokens: Number(value) || 0 });
      st.thinking = value;
      break;
    }
    case "effort": {
      if (typeof value !== "string") throw new Error("effort must be a string");
      await control(sess, "apply_flag_settings", { settings: { effortLevel: value } });
      st.effort = value;
      break;
    }
    case "fastMode": {
      if (typeof value !== "boolean") throw new Error("fastMode must be boolean");
      await control(sess, "apply_flag_settings", { settings: { fastMode: value } });
      st.fastMode = value;
      break;
    }
    default:
      throw new Error(`unsupported claude option: ${id}`);
  }
  emitOptions(sess);
}

async function refreshClaudeOptions(sess: SessionCtx) {
  const st = state(sess);
  if (seedModelChoices(sess, st)) emitOptions(sess);
  const res = await control(sess, "list_models");
  const catalog = normalizeModelCatalog(res?.models);
  st.modelChoices = catalog.choices;
  st.modelMeta = catalog.meta;
  normalizeContext(st);
  normalizeEffort(st);
  emitOptions(sess);
  if (st.commands.length) sess.emit({ kind: "commands", trigger: "/", commands: st.commands });
}

function seedModelChoices(sess: SessionCtx, st: ClaudeState): boolean {
  const seeded = sess.seedOptions?.find((o) => o.id === "model")?.choices;
  if (!seeded || seeded.length <= 1 || st.modelChoices.length > 1) return false;
  st.modelChoices = seeded;
  return true;
}

function emitOptions(sess: SessionCtx) {
  sess.emit({ kind: "options", options: buildOptions(state(sess)), actions: { fork: true } });
}

function buildOptions(st: Pick<ClaudeState, "model" | "modelChoices" | "modelMeta" | "permissionMode" | "thinking" | "effort" | "fastMode" | "context">): SessionOption[] {
  const meta = modelMeta(st);
  const opts: SessionOption[] = [
    { id: "model", label: "Model", kind: "select", value: st.model, choices: st.modelChoices.length ? st.modelChoices : [DEFAULT_MODEL] },
    { id: "permissionMode", label: "Mode", kind: "select", value: st.permissionMode, choices: PERMISSION_CHOICES },
    { id: "thinking", label: "Thinking", kind: "select", value: st.thinking, role: "thinking-budget", choices: THINKING_CHOICES },
    { id: "effort", label: "Effort", kind: "select", value: st.effort, role: "effort", choices: meta.efforts },
  ];
  if (meta.context) opts.push({ id: "context", label: "Context", kind: "select", value: st.context, role: "context", choices: CONTEXT_CHOICES });
  if (meta.supportsFastMode) opts.push({ id: "fastMode", label: "Fast", kind: "toggle", value: st.fastMode });
  return opts;
}

function modelMeta(st: Pick<ClaudeState, "model" | "modelMeta">): ClaudeModelMeta {
  return st.modelMeta.get(st.model) ?? st.modelMeta.get("default") ?? { efforts: EFFORT_CHOICES, supportsFastMode: true };
}

function normalizeEffort(st: Pick<ClaudeState, "model" | "modelMeta" | "effort" | "fastMode">): { effort: boolean; fastMode: boolean } {
  const meta = modelMeta(st);
  const beforeEffort = st.effort;
  const beforeFast = st.fastMode;
  if (!meta.efforts.some((c) => c.value === st.effort)) st.effort = meta.efforts[0]?.value ?? "medium";
  if (!meta.supportsFastMode) st.fastMode = false;
  return { effort: st.effort !== beforeEffort, fastMode: st.fastMode !== beforeFast };
}

function normalizeContext(st: Pick<ClaudeState, "model" | "modelMeta" | "context">): boolean {
  const beforeModel = st.model;
  const beforeContext = st.context;
  if (st.model.endsWith("[1m]")) {
    const base = st.model.slice(0, -4);
    if (st.modelMeta.get(base)?.context) {
      st.model = base;
      st.context = "1M";
    }
  }
  if (!modelMeta(st).context) st.context = "200k";
  if (!CONTEXT_CHOICES.some((c) => c.value === st.context)) st.context = "200k";
  return st.model !== beforeModel || st.context !== beforeContext;
}

function resolveClaudeModelId(st: Pick<ClaudeState, "model" | "modelMeta" | "context">): string {
  const meta = modelMeta(st);
  if (meta.context && st.context === "1M") return meta.context.extended;
  return st.model;
}

function normalizeModelCatalog(models: any): { choices: OptionChoice[]; meta: Map<string, ClaudeModelMeta> } {
  const meta = new Map<string, ClaudeModelMeta>([["default", { efforts: EFFORT_CHOICES, supportsFastMode: true }]]);
  if (!Array.isArray(models)) return { choices: [DEFAULT_MODEL], meta };
  const raw = models.map((m) => {
    const value = String(m.value ?? m.model ?? m.id ?? "default");
    const efforts = Array.isArray(m.supportedEffortLevels) && m.supportedEffortLevels.length
      ? m.supportedEffortLevels.map((e: any) => ({ value: String(e.effortLevel ?? e), label: String(e.effortLevel ?? e) }))
      : EFFORT_CHOICES;
    return {
      value,
      label: String(m.displayName ?? m.name ?? m.value ?? "Model"),
      description: m.description ? String(m.description) : undefined,
      meta: { efforts, supportsFastMode: m.supportsFastMode === true },
    };
  });
  const rawByValue = new Map(raw.map((m) => [m.value, m]));
  const choices: OptionChoice[] = [];
  for (const m of raw) {
    if (m.value.endsWith("[1m]")) {
      const base = m.value.slice(0, -4);
      if (rawByValue.has(base)) continue;
    }
    if (rawByValue.has(`${m.value}[1m]`)) {
      const extended = rawByValue.get(`${m.value}[1m]`)!;
      meta.set(m.value, { ...m.meta, context: { base: m.value, extended: extended.value } });
      choices.push({ value: m.value, label: m.label, description: m.description });
    } else {
      meta.set(m.value, m.meta);
      choices.push({ value: m.value, label: m.label, description: m.description });
    }
  }
  return { choices, meta };
}

async function fetchClaudeModels(cwd: string): Promise<{ choices: OptionChoice[]; meta: Map<string, ClaudeModelMeta> }> {
  const proc = Bun.spawn([
    "claude",
    "-p",
    "--input-format", "stream-json",
    "--output-format", "stream-json",
    "--include-partial-messages",
    "--verbose",
  ], {
    cwd,
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
    env: { ...process.env, CLAUDECODE: undefined, CLAUDE_CODE_ENTRYPOINT: undefined, CLAUDE_CODE_SSE_PORT: undefined },
  });
  try {
    return await new Promise<{ choices: OptionChoice[]; meta: Map<string, ClaudeModelMeta> }>((resolve, reject) => {
      // Claude startup can exceed 12s under heavy system load; the cache
      // makes this a rare cold-path cost, so give it generous headroom.
      const timer = setTimeout(() => reject(new Error("claude model list timed out")), 30_000);
      readLines(proc.stdout, (line) => {
        const ev = tryParse(line);
        if (ev?.type !== "control_response") return;
        const response = ev.response;
        if (response?.request_id !== "cmux-list-options") return;
        clearTimeout(timer);
        if (response.subtype !== "success") reject(new Error(response.error ?? response.message ?? "claude list_models failed"));
        else resolve(normalizeModelCatalog(response.response?.models));
      }, () => {
        clearTimeout(timer);
        reject(new Error("claude exited while listing models"));
      });
      proc.stdin.write(JSON.stringify({
        type: "control_request",
        request_id: "cmux-list-options",
        request: { subtype: "list_models" },
      }) + "\n");
      proc.stdin.flush();
    });
  } finally {
    proc.kill();
  }
}

function handleLine(sess: SessionCtx, line: string) {
  const ev = tryParse(line);
  if (!ev) return;
  if (ev.type === "control_response") {
    const st = state(sess);
    const requestId = ev.response?.request_id;
    const pending = requestId ? st.pending.get(requestId) : undefined;
    if (pending) {
      st.pending.delete(requestId);
      clearTimeout(pending.timer);
      pending.resolve(ev.response);
    }
    return;
  }
  switch (ev.type) {
    case "system":
      if (ev.subtype === "init") {
        const st = state(sess);
        st.commands = normalizeCommands(ev.slash_commands);
        sess.internal.providerSessionId = ev.session_id;
        const fork = sess.internal.claudeFork as { providerSessionId?: string } | undefined;
        if (fork && ev.session_id) fork.providerSessionId = ev.session_id;
        sess.emit({ kind: "meta", model: ev.model, providerSessionId: ev.session_id });
        if (st.commands.length) sess.emit({ kind: "commands", trigger: "/", commands: st.commands });
      } else if (ev.subtype === "status" && ev.permissionMode) {
        state(sess).permissionMode = String(ev.permissionMode);
        emitOptions(sess);
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

function normalizeCommands(commands: any): CommandEntry[] {
  if (!Array.isArray(commands)) return [];
  return commands.map((c) => ({
    name: String(c.name ?? c.command ?? "").replace(/^\/+/, ""),
    description: c.description ? String(c.description) : undefined,
    source: c.source ? String(c.source) : undefined,
  })).filter((c) => c.name);
}
