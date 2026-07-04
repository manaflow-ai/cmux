import type {
  Adapter,
  CommandEntry,
  OptionChoice,
  OptionValue,
  ProviderDef,
  SessionCtx,
  SessionOption,
} from "../types";
import { readLines, tryParse, truncate } from "./lines";

// Generic Agent Client Protocol (https://agentclientprotocol.com) client over
// stdio NDJSON JSON-RPC. One adapter covers every ACP-speaking agent:
// `opencode acp`, `gemini --experimental-acp`, `claude-code-acp`, goose, ...
export function makeAcpAdapter(def: ProviderDef): Adapter {
  const adapter: Adapter = {
    capabilities: {
      triggers: ["/"],
      options: [
        { id: "model", label: "Model", kind: "select", value: "", disabled: true, description: "Loads at start" },
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
      ],
    },
    async send(sess, prompt) {
      sess.setStatus("running");
      try {
        const st = await ensureAcp(sess, def);
        await applyInitialOptions(sess, st);
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
      if (st?.acpSessionId) st.notify("session/cancel", { sessionId: st.acpSessionId });
    },
    dispose(sess) {
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
      await setAcpOption(sess, st, id, value);
    },
    async refreshOptions(sess) {
      const st = await ensureAcp(sess, def);
      emitAcpState(sess, st);
    },
    async listOptions() {
      return adapter.capabilities?.options ?? [];
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
  sources: Map<string, "config" | "mode" | "model">;
  commands: CommandEntry[];
  initialApplied: boolean;
}

async function ensureAcp(sess: SessionCtx, def: ProviderDef): Promise<AcpState> {
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

async function startAcp(sess: SessionCtx, def: ProviderDef): Promise<AcpState> {
  const cmd = [...(def.cmd ?? [])];
  if (sess.autoApprove && def.autoApproveArgs) cmd.push(...def.autoApproveArgs);
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
    commands: [],
    initialApplied: false,
  };

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
    if (msg.method) handleAgentMessage(sess, st, msg, writeMsg);
  }, () => {
    for (const p of pending.values()) p.reject(new Error(`${def.id} acp process exited`));
    pending.clear();
    if (sess.internal.acp && (sess.internal.acp as AcpState).proc === proc) {
      sess.internal.acp = undefined;
    }
  });
  readLines(proc.stderr, () => {});

  try {
    await request("initialize", {
      protocolVersion: 1,
      clientCapabilities: { fs: { readTextFile: false, writeTextFile: false } },
    });
    const created = await request("session/new", { cwd: sess.cwd, mcpServers: [] });
    st.acpSessionId = created.sessionId;
    ingestAcpOptions(st, created);
    sess.internal.acp = st;
    sess.emit({ kind: "meta", providerSessionId: created.sessionId });
    emitAcpState(sess, st);
    return st;
  } catch (err) {
    proc.kill();
    throw err;
  }
}

async function applyInitialOptions(sess: SessionCtx, st: AcpState) {
  if (st.initialApplied) return;
  st.initialApplied = true;
  for (const [id, value] of Object.entries(sess.startOptions)) {
    if (st.sources.has(id)) await setAcpOption(sess, st, id, value);
  }
}

async function setAcpOption(sess: SessionCtx, st: AcpState, id: string, value: OptionValue) {
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
    if (res?.configOptions) ingestAcpOptions(st, res);
    else updateLocalOption(st, id, value);
  } else if (source === "mode") {
    if (typeof value !== "string") throw new Error("mode must be a string");
    await st.request("session/set_mode", { sessionId: st.acpSessionId, modeId: value });
    updateLocalOption(st, id, value);
  } else if (source === "model") {
    if (typeof value !== "string") throw new Error("model must be a string");
    await st.request("session/set_model", { sessionId: st.acpSessionId, modelId: value });
    updateLocalOption(st, id, value);
  }
  emitAcpState(sess, st);
}

function ingestAcpOptions(st: AcpState, payload: any) {
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
        label: String(m.name ?? m.modelId ?? m.id),
        description: m.description ? String(m.description) : undefined,
      })),
    });
    sources.set("model", "model");
  }
  st.options = [...options.values()];
  st.sources = sources;
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
  if (st.options.length) sess.emit({ kind: "options", options: st.options });
  if (st.commands.length) sess.emit({ kind: "commands", trigger: "/", commands: st.commands });
}

// Notifications and reverse requests from the agent.
function handleAgentMessage(sess: SessionCtx, st: AcpState, msg: any, writeMsg: (m: unknown) => void) {
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
          ingestAcpOptions(st, u);
          emitAcpState(sess, st);
        }
        break;
    }
    if (u.configOptions || u.modes || u.models) {
      ingestAcpOptions(st, u);
      emitAcpState(sess, st);
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

function normalizeCommands(commands: any): CommandEntry[] {
  if (!Array.isArray(commands)) return [];
  return commands.map((c) => ({
    name: String(c.name ?? "").replace(/^\/+/, ""),
    description: c.description ? String(c.description) : undefined,
    source: c.source ? String(c.source) : undefined,
  })).filter((c) => c.name);
}

function contentText(content: unknown): string {
  if (!Array.isArray(content)) return "";
  return content
    .map((c: any) => c?.content?.text ?? c?.text ?? "")
    .join("");
}

async function fetchAcpCommands(def: ProviderDef, cwd: string): Promise<CommandEntry[]> {
  if (!def.cmd?.length) return [];
  const proc = Bun.spawn([...def.cmd], {
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
    proc.kill();
  }
}
