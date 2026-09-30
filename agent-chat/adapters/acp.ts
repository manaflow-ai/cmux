import type {
  Adapter,
  AgentEvent,
  AgentPlanEntry,
  AgentPlanStatus,
  CommandEntry,
  OptionChoice,
  OptionValue,
  ProviderDef,
  SessionCtx,
  SessionOption,
} from "../types";
import { readLines, tryParse, truncate } from "./lines";
import { prettifyModelLabel } from "./model-label";

/**
 * The provider-neutral part of a durable cmux agent message that an ACP
 * session needs in order to answer in context. Keeping this translation at
 * the adapter boundary lets a future mailbox deliver messages without making
 * ACP providers aware of cmux's storage or routing implementation.
 */
export interface AcpMailMessage {
  /** Same field names as the durable `MailEnvelope`, without importing it. */
  id: string;
  threadId: string;
  sender: string;
  recipients: readonly string[];
  subject?: string;
  inReplyTo?: string;
  body: string;
}

/**
 * Render a durable message as ordinary ACP prompt text. The existing ACP
 * `session/prompt` request remains unchanged; callers pass this result to
 * `adapter.send` just like any other prompt. JSON keeps untrusted fields
 * structurally separate while leaving the body readable to the receiving agent.
 */
export function acpPromptFromMail(message: AcpMailMessage): string {
  return [
    "cmux-agent-message-json-v1:",
    JSON.stringify({
      messageId: message.id,
      threadId: message.threadId,
      from: message.sender,
      to: [...message.recipients],
      ...(message.subject === undefined ? {} : { subject: message.subject }),
      ...(message.inReplyTo === undefined ? {} : { inReplyTo: message.inReplyTo }),
      body: message.body,
    }, null, 2),
  ].join("\n");
}

// Generic Agent Client Protocol (https://agentclientprotocol.com) client over
// stdio NDJSON JSON-RPC. One adapter covers every ACP-speaking agent:
// `opencode acp`, `gemini --experimental-acp`, `claude-code-acp`, goose, ...
export function makeAcpAdapter(def: ProviderDef): Adapter {
  const fallbackOptions = acpFallbackOptions(def);
  const adapter: Adapter = {
    capabilities: {
      triggers: ["/"],
      options: fallbackOptions,
    },
    async send(sess, prompt, generation?: number) {
      // ACP has no mid-turn steer and most agents reject overlapping
      // session/prompt calls, so serialize sends: a prompt sent while a turn
      // is in flight runs after that turn resolves.
      sess.setStatus("running");
      const sequence = Number(sess.internal.acpTurnSequence ?? 0) + 1;
      sess.internal.acpTurnSequence = sequence;
      const prev = (sess.internal.acpTurn as Promise<void> | undefined) ?? Promise.resolve();
      const turn = prev.then(async () => {
        if (sess.internal.acpDisposed) return;
        const cancelled = () => sequence <= Number(sess.internal.acpCancelledSequence ?? 0);
        if (cancelled()) {
          sess.emit({ kind: "done", stats: "stop: cancelled", generation } as any);
        } else {
          try {
            const st = await ensureAcp(sess, def);
            if (!st || sess.internal.acpDisposed) return;
            if (cancelled()) {
              sess.emit({ kind: "done", stats: "stop: cancelled", generation } as any);
            } else {
              await applyInitialOptions(sess, st, def);
              if (sess.internal.acpDisposed) return;
              if (cancelled()) {
                sess.emit({ kind: "done", stats: "stop: cancelled", generation } as any);
              } else {
                const res = await st.request("session/prompt", {
                  sessionId: st.acpSessionId,
                  prompt: [{ type: "text", text: prompt }],
                });
                if (sess.internal.acpDisposed) return;
                sess.emit({ kind: "done", stats: res?.stopReason ? `stop: ${res.stopReason}` : undefined, generation } as any);
              }
            }
          } catch (err) {
            if (sess.internal.acpDisposed) return;
            // Startup can reject long after a cancel, up to the 30s watchdog
            // below, so a cancelled turn reports the cancel rather than an
            // error for a turn the user already stopped.
            if (cancelled()) {
              sess.emit({ kind: "done", stats: "stop: cancelled", generation } as any);
            } else {
              sess.emit({ kind: "error", message: truncate(String(err), 400) });
              sess.emit({ kind: "done", generation } as any);
            }
          }
        }
        if (sess.internal.acpTurn === turn) sess.setStatus("idle");
      });
      sess.internal.acpTurn = turn;
      await turn;
    },
    stop(sess) {
      sess.internal.acpCancelledSequence = Number(sess.internal.acpTurnSequence ?? 0);
      const st = sess.internal.acp as AcpState | undefined;
      // A cancel during startup has no session to notify, and the queued turn
      // only reaches its own idle/done handling after ensureAcp settles, so
      // settle the status here instead of leaving it running until startup
      // times out. Published state without a session id is a different case:
      // the agent answered session/new without one, so the turn is live and
      // uncancellable and its own handling still owns the status.
      if (st?.acpSessionId) st.notify("session/cancel", { sessionId: st.acpSessionId });
      else if (!st) sess.setStatus("idle");
    },
    dispose(sess) {
      sess.internal.acpDisposed = true;
      const st = sess.internal.acp as AcpState | undefined;
      const startingProc = sess.internal.acpStartingProc as AcpState["proc"] | undefined;
      sess.internal.acp = undefined;
      sess.internal.acpStarting = undefined;
      sess.internal.acpStartingProc = undefined;
      st?.proc.kill();
      startingProc?.kill();
    },
    async setOption(sess, id, value) {
      const st = await ensureAcp(sess, def);
      if (!st) return;
      await setAcpOption(sess, st, def, id, value);
    },
    async refreshOptions(sess) {
      const st = await ensureAcp(sess, def);
      if (!st) return;
      ingestAcpOptions(st, {}, def, String(st.options.find((option) => option.id === "model")?.value ?? ""));
      emitAcpState(sess, st);
    },
    async listOptions(cwd) {
      return withAcpLocalOptions(await fetchAcpOptions(def, cwd, fallbackOptions), true);
    },
    async listCommands(cwd) {
      return [{ trigger: "/", commands: await fetchAcpCommands(def, cwd) }];
    },
  };
  return adapter;
}

interface AcpState {
  proc: Bun.Subprocess<"pipe", "pipe", "pipe">;
  acpSessionId: string;
  request(method: string, params: unknown): Promise<any>;
  notify(method: string, params: unknown): void;
  options: SessionOption[];
  sources: Map<string, "config" | "mode" | "model" | "spawnModel">;
  autoApprove: boolean;
  commands: CommandEntry[];
  initialApplied: boolean;
}

async function reapAcpProcess(proc: AcpState["proc"]): Promise<void> {
  // A previous SIGTERM may have been ignored; `killed` only records that a
  // signal was sent. Every unpublished or disposable child must actually exit.
  if (proc.exitCode === null) proc.kill("SIGKILL");
  await proc.exited;
}

function acpFallbackOptions(def: ProviderDef): SessionOption[] {
  const model = def.models?.length
    ? { id: "model", label: "Model", kind: "select" as const, value: def.defaultModel ?? def.models[0]!.value, choices: def.models }
    : { id: "model", label: "Model", kind: "select" as const, value: "", disabled: true, description: "Loads at start" };
  return [
    model,
    {
      id: "mode",
      label: "Mode",
      kind: "select",
      value: "build",
      choices: [
        { value: "build", label: "build" },
        { value: "plan", label: "plan" },
      ],
    },
    { id: "autoApprove", label: "Auto-approve", kind: "toggle", value: true, role: "approval" },
  ];
}

function effectiveSpawnModel(def: ProviderDef, options: Record<string, OptionValue>): string {
  return typeof options.model === "string" && def.models?.some((m) => m.value === options.model)
    ? options.model
    : def.defaultModel ?? def.models?.[0]?.value ?? "";
}

export function commandForSession(def: ProviderDef, options: Record<string, OptionValue>): string[] {
  const cmd = [...(def.cmd ?? [])];
  if (def.models?.length) {
    cmd.push("--model", effectiveSpawnModel(def, options));
  }
  return cmd;
}

async function ensureAcp(sess: SessionCtx, def: ProviderDef): Promise<AcpState | undefined> {
  if (sess.internal.acpDisposed) return;
  const existing = sess.internal.acp as AcpState | undefined;
  if (existing && existing.proc.exitCode === null && !existing.proc.killed) return existing;
  const starting = sess.internal.acpStarting as Promise<AcpState> | undefined;
  if (starting) return starting;

  const promise = startAcp(sess, def).finally(() => {
    if (sess.internal.acpStarting === promise) sess.internal.acpStarting = undefined;
    sess.internal.acpStartingProc = undefined;
  });
  sess.internal.acpStarting = promise;
  return promise;
}

async function startAcp(sess: SessionCtx, def: ProviderDef): Promise<AcpState | undefined> {
  if (sess.internal.acpDisposed) return;
  const spawnModel = effectiveSpawnModel(def, sess.startOptions);
  const cmd = commandForSession(def, sess.startOptions);
  const autoApprove = typeof sess.startOptions.autoApprove === "boolean" ? sess.startOptions.autoApprove : sess.autoApprove;
  if (autoApprove && def.autoApproveArgs) cmd.push(...def.autoApproveArgs);
  const proc = Bun.spawn(cmd, {
    cwd: sess.cwd,
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
    env: { ...process.env },
  });
  sess.internal.acpStartingProc = proc;

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

  const st: AcpState = {
    proc,
    acpSessionId: "",
    request,
    notify,
    options: [],
    sources: new Map(),
    autoApprove,
    commands: [],
    initialApplied: false,
  };

  readLines(proc.stdout, (line) => {
    const msg = tryParse(line);
    if (!msg) return;
    if (msg.jsonrpc !== undefined && msg.jsonrpc !== "2.0") return;
    if (msg.id != null && (msg.result !== undefined || msg.error !== undefined)) {
      const p = pending.get(msg.id);
      if (p) {
        pending.delete(msg.id);
        msg.error ? p.reject(new Error(msg.error.message ?? "acp error")) : p.resolve(msg.result);
      }
      return;
    }
    if (msg.method) handleAgentMessage(sess, st, def, msg, writeMsg);
  }, () => {
    for (const p of pending.values()) p.reject(new Error(`${def.id} acp process exited`));
    pending.clear();
    if (sess.internal.acp && (sess.internal.acp as AcpState).proc === proc) {
      sess.internal.acp = undefined;
    }
  });
  readLines(proc.stderr, () => {});

  // An agent that starts but never answers initialize/session/new would leave
  // the session stuck in "running" with nothing to cancel; killing the process
  // closes stdout, which rejects the pending startup requests.
  let startupTimedOut = false;
  const startupTimer = setTimeout(() => {
    startupTimedOut = true;
    proc.kill("SIGKILL");
  }, 30_000);
  try {
    await request("initialize", {
      protocolVersion: 1,
      clientCapabilities: { fs: { readTextFile: false, writeTextFile: false } },
    });
    const created = await request("session/new", { cwd: sess.cwd, mcpServers: [] });
    if (sess.internal.acpDisposed) {
      await reapAcpProcess(proc);
      return;
    }
    st.acpSessionId = created.sessionId;
    ingestAcpOptions(st, created, def, spawnModel);
    sess.internal.acp = st;
    sess.emit({ kind: "meta", providerSessionId: created.sessionId });
    emitAcpState(sess, st);
    return st;
  } catch (err) {
    // Reap this unpublished agent before clearing acpStarting so a retry
    // cannot accumulate children that rejected startup or ignored SIGTERM.
    clearTimeout(startupTimer);
    await reapAcpProcess(proc);
    throw startupTimedOut ? new Error(`${def.id} did not finish ACP startup within 30s`) : err;
  } finally {
    clearTimeout(startupTimer);
  }
}

async function applyInitialOptions(sess: SessionCtx, st: AcpState, def: ProviderDef) {
  if (st.initialApplied) return;
  st.initialApplied = true;
  for (const [id, value] of Object.entries(sess.startOptions)) {
    if (id === "autoApprove" || (st.sources.has(id) && !(id === "model" && st.sources.get(id) === "spawnModel"))) {
      await setAcpOption(sess, st, def, id, value);
    }
  }
}

async function setAcpOption(sess: SessionCtx, st: AcpState, def: ProviderDef, id: string, value: OptionValue) {
  if (id === "autoApprove") {
    if (typeof value !== "boolean") throw new Error("autoApprove must be boolean");
    st.autoApprove = value;
    emitAcpState(sess, st);
    return;
  }
  const source = st.sources.get(id);
  if (!source) throw new Error(`unsupported ${sess.provider} option: ${id}`);
  if (source === "config") {
    const params = { sessionId: st.acpSessionId, configId: id, value };
    let res: any;
    try {
      res = await st.request("session/set_config_option", params);
    } catch (err) {
      if (!String(err).includes("Method not found")) throw err;
      res = await st.request("session/set_config", params);
    }
    if (res?.configOptions) ingestAcpOptions(st, res, def);
    else updateLocalOption(st, id, value);
  } else if (source === "mode") {
    if (typeof value !== "string") throw new Error("mode must be a string");
    await st.request("session/set_mode", { sessionId: st.acpSessionId, modeId: value });
    updateLocalOption(st, id, value);
  } else if (source === "model") {
    if (typeof value !== "string") throw new Error("model must be a string");
    await st.request("session/set_model", { sessionId: st.acpSessionId, modelId: value });
    updateLocalOption(st, id, value);
  } else if (source === "spawnModel") {
    if (typeof value !== "string") throw new Error("model must be a string");
    sess.startOptions.model = value;
    updateLocalOption(st, id, value);
    emitAcpState(sess, st);
    sess.emit({ kind: "status", text: "model changed, conversation restarted" });
    const proc = st.proc;
    if ((sess.internal.acp as AcpState | undefined) === st) sess.internal.acp = undefined;
    proc.kill();
    await ensureAcp(sess, def);
    return;
  }
  emitAcpState(sess, st);
}

function ingestAcpOptions(st: AcpState, payload: any, def?: ProviderDef, spawnModel?: string) {
  const options = new Map(st.options.map((o) => [o.id, o] as const));
  const sources = new Map(st.sources);
  for (const opt of payload.configOptions ?? []) {
    const mapped = configOption(opt);
    if (!mapped) continue;
    options.set(mapped.id, mapped);
    sources.set(mapped.id, "config");
  }
  if (payload.modes && sources.get("mode") !== "config") {
    const modes = payload.modes;
    options.set("mode", {
      id: "mode",
      label: "Mode",
      kind: "select",
      value: String(modes.currentModeId ?? ""),
      choices: (modes.availableModes ?? []).map((m: any) => ({
        value: String(m.id),
        label: String(m.name ?? m.id),
        description: m.description ? String(m.description) : undefined,
      })),
    });
    sources.set("mode", "mode");
  }
  if (payload.models && sources.get("model") !== "config") {
    const models = payload.models;
    options.set("model", {
      id: "model",
      label: "Model",
      kind: "select",
      value: String(models.currentModelId ?? ""),
      choices: (models.availableModels ?? []).map((m: any) => ({
        value: String(m.modelId ?? m.id),
        label: prettifyModelLabel(String(m.name ?? m.modelId ?? m.id)),
        description: m.description ? String(m.description) : undefined,
      })),
    });
    sources.set("model", "model");
  }
  if (def?.models?.length) {
    options.set("model", mergeAcpModelOption(options.get("model"), def.models, def.defaultModel, spawnModel));
    sources.set("model", "spawnModel");
  }
  st.options = [...options.values()];
  st.sources = sources;
}

export function mergeAcpModelOption(
  existing: SessionOption | undefined,
  curated: OptionChoice[],
  defaultModel?: string,
  spawnModel?: string,
): SessionOption {
  const binary = new Map((existing?.choices ?? []).map((choice) => [choice.value, choice]));
  const choices: OptionChoice[] = curated.map((choice) => {
    const reported = binary.get(choice.value);
    binary.delete(choice.value);
    return { ...reported, ...choice };
  });
  choices.push(...binary.values());
  const value = String(spawnModel || existing?.value || defaultModel || choices[0]?.value || "");
  if (value && !choices.some((choice) => choice.value === value)) {
    choices.push({ value, label: prettifyModelLabel(value), description: "Reported by the agent" });
  }
  return { id: "model", label: "Model", kind: "select", value, choices };
}

function configOption(opt: any): SessionOption | null {
  if (!opt?.id) return null;
  if (opt.type === "select") {
    return {
      id: String(opt.id),
      label: String(opt.name ?? opt.id),
      kind: "select",
      value: String(opt.currentValue ?? ""),
      choices: flattenChoices(opt.options),
      description: opt.description ? String(opt.description) : undefined,
    };
  }
  if (opt.type === "boolean") {
    return {
      id: String(opt.id),
      label: String(opt.name ?? opt.id),
      kind: "toggle",
      value: Boolean(opt.currentValue),
      description: opt.description ? String(opt.description) : undefined,
    };
  }
  return null;
}

function flattenChoices(raw: any): OptionChoice[] {
  if (!Array.isArray(raw)) return [];
  return raw.flatMap((item) => {
    if (Array.isArray(item.options)) return flattenChoices(item.options);
    return [{
      value: String(item.value),
      label: String(item.name ?? item.label ?? item.value),
      description: item.description ? String(item.description) : undefined,
    }];
  });
}

function updateLocalOption(st: AcpState, id: string, value: OptionValue) {
  st.options = st.options.map((o) => o.id === id ? { ...o, value } : o);
}

function emitAcpState(sess: SessionCtx, st: AcpState) {
  sess.emit({ kind: "options", options: withAcpLocalOptions(st.options, st.autoApprove) });
  if (st.commands.length) sess.emit({ kind: "commands", trigger: "/", commands: st.commands });
}

function withAcpLocalOptions(options: SessionOption[], autoApprove: boolean): SessionOption[] {
  return [
    ...options.filter((o) => o.id !== "autoApprove"),
    { id: "autoApprove", label: "Auto-approve", kind: "toggle", value: autoApprove, role: "approval" },
  ];
}

function normalizeAcpPlanStatus(status: unknown): AgentPlanStatus {
  return status === "pending" || status === "in_progress" || status === "completed" ? status : "unknown";
}

function normalizeAcpPlanEntries(entries: unknown): AgentPlanEntry[] {
  if (!Array.isArray(entries)) return [];
  return entries.map((entry: any) => ({
    text: typeof entry?.content === "string" ? entry.content : String(entry?.content ?? ""),
    status: normalizeAcpPlanStatus(entry?.status),
    ...(entry?.priority == null ? {} : { priority: String(entry.priority) }),
  }));
}

function acpPlanEvent(entries: unknown): Extract<AgentEvent, { kind: "plan" }> | null {
  const normalized = normalizeAcpPlanEntries(entries);
  return normalized.length ? { kind: "plan", entries: normalized } : null;
}

// Notifications and reverse requests from the agent.
function handleAgentMessage(sess: SessionCtx, st: AcpState, def: ProviderDef, msg: any, writeMsg: (m: unknown) => void) {
  if (sess.internal.acpDisposed) return;
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
          detail: acpToolCallDetail(u.locations, u.rawInput),
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
        {
          const plan = acpPlanEvent(u.entries);
          if (plan) sess.emit(plan);
        }
        break;
      case "available_commands_update":
        st.commands = normalizeCommands(u.availableCommands);
        sess.emit({ kind: "commands", trigger: "/", commands: st.commands });
        break;
      case "current_mode_update":
        if (u.currentModeId) {
          updateLocalOption(st, "mode", String(u.currentModeId));
          emitAcpState(sess, st);
        }
        break;
      case "config_option_update":
      case "config_options_update":
        if (u.configOptions) {
          ingestAcpOptions(st, u, def);
          emitAcpState(sess, st);
        }
        break;
    }
    if (u.configOptions || u.modes || u.models) {
      ingestAcpOptions(st, u, def);
      emitAcpState(sess, st);
    }
    return;
  }
  // Reverse request: must answer or the agent hangs.
  if (msg.id != null && msg.method === "session/request_permission") {
    const options: any[] = msg.params?.options ?? [];
    const allow = options.find((o) => o.kind === "allow_always")
      ?? options.find((o) => o.kind === "allow_once");
    // Never fall back to an arbitrary option when denying: if the agent only
    // offered allow options, picking options[0] would approve the tool even
    // though auto-approve is off. "cancelled" is the spec's no-selection
    // outcome.
    const reject = options.find((o) => o.kind?.startsWith("reject"));
    const choice = st.autoApprove && allow ? allow : reject;
    if (choice !== allow) {
      const tc = msg.params?.toolCall;
      sess.emit({ kind: "status", text: `denied: ${truncate(tc?.title ?? "tool", 120)} (auto-approve is off)` });
    }
    writeMsg({
      jsonrpc: "2.0",
      id: msg.id,
      result: {
        outcome: choice
          ? { outcome: "selected", optionId: choice.optionId }
          : { outcome: "cancelled" },
      },
    });
    return;
  }
  if (msg.id != null) {
    writeMsg({ jsonrpc: "2.0", id: msg.id, error: { code: -32601, message: "method not supported by cmux-agent-ui" } });
  }
}

function normalizeCommands(commands: any): CommandEntry[] {
  if (!Array.isArray(commands)) return [];
  return commands.map((c) => ({
    name: String(c.name ?? "").replace(/^\/+/, ""),
    description: c.description ? String(c.description) : undefined,
    source: c.source ? String(c.source) : undefined,
  })).filter((c) => c.name);
}

export function acpToolCallDetail(locations: unknown, rawInput: unknown): string {
  const paths = Array.isArray(locations)
    ? locations
      .map((location: any) => typeof location?.path === "string" ? location.path : "")
      .filter(Boolean)
    : [];
  return truncate(paths.length ? paths.join(", ") : JSON.stringify(rawInput ?? {}));
}

function lineCount(text: string): number {
  return text ? text.split(/\r\n|\r|\n/).length : 0;
}

function diffText(content: any): string {
  const oldText = typeof content.oldText === "string" ? content.oldText : "";
  const newText = typeof content.newText === "string" ? content.newText : "";
  const path = typeof content.path === "string" && content.path ? content.path : "unknown path";
  return `diff ${path} (+${lineCount(newText)}/-${lineCount(oldText)})${newText ? `\n${newText}` : ""}`;
}

export function contentText(content: unknown): string {
  if (!Array.isArray(content)) return "";
  const parts = content.map((c: any) => ({
    text: c?.type === "diff"
      ? diffText(c)
      : c?.type === "terminal"
        ? `terminal ${String(c.terminalId ?? "")}`.trim()
        : c?.content?.text ?? c?.text ?? "",
    separate: c?.type === "diff" || c?.type === "terminal",
  }));
  return parts
    .map((part, index) => `${index > 0 && (part.separate || parts[index - 1]!.separate) ? " " : ""}${part.text}`)
    .join("");
}

async function fetchAcpCommands(def: ProviderDef, cwd: string): Promise<CommandEntry[]> {
  if (!def.cmd?.length) return [];
  const proc = Bun.spawn(commandForSession(def, {}), {
    cwd,
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
    env: { ...process.env },
  });
  try {
    return await new Promise<CommandEntry[]>((resolve, reject) => {
      let nextId = 1;
      const pending = new Set<number>();
      const write = (method: string, params: unknown) => {
        const id = nextId++;
        pending.add(id);
        proc.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
        proc.stdin.flush();
        return id;
      };
      const timer = setTimeout(() => resolve([]), 8_000);
      readLines(proc.stdout, (line) => {
        const msg = tryParse(line);
        if (!msg) return;
        if (msg.id != null && pending.has(msg.id)) {
          pending.delete(msg.id);
          if (msg.error) {
            clearTimeout(timer);
            reject(new Error(msg.error.message ?? "acp command catalog failed"));
          } else if (msg.id === 1) {
            write("session/new", { cwd, mcpServers: [] });
          }
          return;
        }
        if (msg.method === "session/update" && msg.params?.update?.sessionUpdate === "available_commands_update") {
          clearTimeout(timer);
          resolve(normalizeCommands(msg.params.update.availableCommands));
        }
      }, () => {
        clearTimeout(timer);
        resolve([]);
      });
      write("initialize", {
        protocolVersion: 1,
        clientCapabilities: { fs: { readTextFile: false, writeTextFile: false } },
      });
    });
  } finally {
    await reapAcpProcess(proc);
  }
}

async function fetchAcpOptions(def: ProviderDef, cwd: string, fallback: SessionOption[]): Promise<SessionOption[]> {
  if (!def.cmd?.length) return fallback;
  const proc = Bun.spawn(commandForSession(def, {}), {
    cwd,
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
    env: { ...process.env },
  });
  try {
    return await new Promise<SessionOption[]>((resolve, reject) => {
      let nextId = 1;
      const pending = new Set<number>();
      const write = (method: string, params: unknown) => {
        const id = nextId++;
        pending.add(id);
        proc.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
        proc.stdin.flush();
        return id;
      };
      const timer = setTimeout(() => resolve(fallback), 8_000);
      readLines(proc.stdout, (line) => {
        const msg = tryParse(line);
        if (!msg || msg.id == null || !pending.has(msg.id)) return;
        pending.delete(msg.id);
        if (msg.error) {
          clearTimeout(timer);
          reject(new Error(msg.error.message ?? "acp option catalog failed"));
        } else if (msg.id === 1) {
          write("session/new", { cwd, mcpServers: [] });
        } else {
          clearTimeout(timer);
          const st: AcpState = {
            proc,
            acpSessionId: "",
            request: () => Promise.reject(new Error("catalog probe closed")),
            notify: () => {},
            options: [],
            sources: new Map(),
            autoApprove: true,
            commands: [],
            initialApplied: false,
          };
          ingestAcpOptions(st, msg.result ?? {}, def, effectiveSpawnModel(def, {}));
          resolve(st.options.length ? st.options : fallback);
        }
      }, () => {
        clearTimeout(timer);
        resolve(fallback);
      });
      write("initialize", {
        protocolVersion: 1,
        clientCapabilities: { fs: { readTextFile: false, writeTextFile: false } },
      });
    });
  } finally {
    await reapAcpProcess(proc);
  }
}
