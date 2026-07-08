// Client-side session state: one WebSocket, one session per page.
import { useCallback, useEffect, useRef, useState } from "react";

export type AgentEvent =
  | { kind: "meta"; model?: string; providerSessionId?: string }
  | { kind: "options"; options: SessionOption[]; actions?: SessionActions }
  | { kind: "commands"; trigger: CommandTrigger; commands: CommandEntry[] }
  | { kind: "user"; text: string }
  | { kind: "status"; text: string }
  | { kind: "delta"; text: string }
  | { kind: "assistant"; text: string }
  | { kind: "thinking"; text: string }
  | { kind: "tool-start"; toolId: string; name: string; detail?: string }
  | { kind: "tool-end"; toolId: string; name?: string; detail?: string; ok?: boolean }
  | { kind: "done"; stats?: string }
  | { kind: "files-changed"; files: ChangedFile[] }
  | { kind: "error"; message: string };

export type OptionKind = "select" | "toggle";
export type OptionValue = string | boolean;
export type CommandTrigger = "/" | "$" | "@";
export interface OptionChoice { value: string; label: string; description?: string; disabled?: boolean; disabledReason?: string; }
export interface SessionOption {
  id: string;
  label: string;
  kind: OptionKind;
  value: OptionValue;
  role?: "effort" | "thinking-budget" | "approval" | "context";
  choices?: OptionChoice[];
  disabled?: boolean;
  description?: string;
}
export interface CommandEntry { name: string; description?: string; source?: string; }
export interface CommandGroup { trigger: CommandTrigger; commands: CommandEntry[]; }
export interface ProviderCapabilities { options: SessionOption[]; triggers: CommandTrigger[]; }
export interface SessionActions { fork?: boolean; }
export interface ChangedFile { path: string; adds: number; dels: number; status: string; }

const diffKeySeparator = "\0";

export function fileDiffCacheKey(revision: string, path: string): string {
  return `${revision}${diffKeySeparator}${path}`;
}

export function decodeFileDiffRequest(value: string): { key: string; path: string } {
  const index = value.indexOf(diffKeySeparator);
  if (index < 0) return { key: value, path: value };
  return { key: value, path: value.slice(index + diffKeySeparator.length) };
}

function nextFilesRevision(blocks: Block[]): string {
  let count = 0;
  for (const block of blocks) {
    if (block.kind === "files") count += 1;
  }
  return String(count + 1);
}

export type Block =
  | { kind: "user"; text: string }
  | { kind: "assistant"; text: string; open: boolean }
  | { kind: "thinking"; text: string; open: boolean }
  | { kind: "tool"; toolId: string; name: string; detail?: string; status: "running" | "ok" | "fail"; out?: string }
  | { kind: "status"; text: string }
  | { kind: "error"; text: string }
  | { kind: "footer"; text: string }
  | { kind: "files"; files: ChangedFile[]; revision?: string };

export interface Provider { id: string; label: string; iconUrl?: string; iconDarkUrl?: string; installed?: boolean; installCommand?: string; }
export interface SessionSummary { id: string; provider: string; cwd: string; title: string; status: string; capabilities?: ProviderCapabilities; }
export type CtrlJMode = "newline" | "menu";

function closeStreaming(blocks: Block[]): Block[] {
  const last = blocks[blocks.length - 1];
  if (last && (last.kind === "assistant" || last.kind === "thinking") && last.open) {
    return [...blocks.slice(0, -1), { ...last, open: false }];
  }
  return blocks;
}

export function foldEvent(blocks: Block[], evt: AgentEvent): Block[] {
  const last = blocks[blocks.length - 1];
  switch (evt.kind) {
    case "user":
      return [...closeStreaming(blocks), { kind: "user", text: evt.text }];
    case "delta":
      if (last && last.kind === "assistant" && last.open) {
        return [...blocks.slice(0, -1), { ...last, text: last.text + evt.text }];
      }
      return [...closeStreaming(blocks), { kind: "assistant", text: evt.text, open: true }];
    case "assistant":
      if (last && last.kind === "assistant" && last.open) {
        return [...blocks.slice(0, -1), { ...last, text: evt.text, open: false }];
      }
      return [...closeStreaming(blocks), { kind: "assistant", text: evt.text, open: false }];
    case "thinking":
      if (last && last.kind === "thinking" && last.open) {
        return [...blocks.slice(0, -1), { ...last, text: last.text + evt.text }];
      }
      return [...closeStreaming(blocks), { kind: "thinking", text: evt.text, open: true }];
    case "tool-start":
      return [...closeStreaming(blocks), { kind: "tool", toolId: evt.toolId, name: evt.name || "tool", detail: evt.detail, status: "running" }];
    case "tool-end":
      return blocks.map((b) =>
        b.kind === "tool" && b.toolId === evt.toolId
          ? { ...b, status: evt.ok === false ? "fail" : "ok", out: evt.detail || b.out }
          : b,
      );
    case "done": {
      const closed = closeStreaming(blocks);
      return [...closed, { kind: "footer", text: evt.stats ?? "" }];
    }
    case "files-changed":
      return [...closeStreaming(blocks), { kind: "files", files: evt.files, revision: nextFilesRevision(blocks) }];
    case "error":
      return [...closeStreaming(blocks), { kind: "error", text: evt.message }];
    case "status":
      return [...closeStreaming(blocks), { kind: "status", text: evt.text }];
    default:
      return blocks;
  }
}

interface Hello { providers: Provider[]; defaultCwd: string; keys?: { ctrlJ?: CtrlJMode }; }

export interface SessionState {
  ready: boolean;
  connectionEpoch: number;
  providers: Provider[];
  capabilities: Record<string, ProviderCapabilities>;
  defaultCwd: string;
  ctrlJ: CtrlJMode;
  phase: "composer" | "chat";
  session: SessionSummary | null;
  blocks: Block[];
  options: SessionOption[];
  actions: SessionActions;
  commands: CommandGroup[];
  providerOptions: Record<string, SessionOption[]>;
  providerCommands: Record<string, CommandGroup[]>;
  filesByCwd: Record<string, string[]>;
  cwdChecks: Record<string, { ok: boolean; message?: string }>;
  fileDiffs: Record<string, string>;
  lastError: string;
  forkPending: boolean;
  start(opts: { provider: string; cwd: string; prompt: string; options?: Record<string, OptionValue> }): boolean;
  compose(): void;
  reply(text: string): void;
  stop(): void;
  setOption(id: string, value: OptionValue): void;
  fork(): void;
  requestProviderOptions(provider: string, cwd: string): void;
  requestProviderCommands(provider: string, cwd: string): void;
  requestFiles(cwd: string, query?: string): void;
  requestFileDiff(sessionId: string, path: string): void;
  checkCwd(cwd: string): void;
  clearError(): void;
}

const routedSessionId = (location.pathname.match(/^\/s\/([\w-]+)/) || [])[1] || null;
export const composerDraftKey = "agentui.draft";
const PENDING_START_TIMEOUT_MS = 30_000;

export function restoreComposerDraft(storage: Pick<Storage, "setItem">, prompt: string) {
  storage.setItem(composerDraftKey, prompt);
}

export function consumeOptimisticUserEcho(queue: string[], text: string): boolean {
  if (queue[0] !== text) return false;
  queue.shift();
  return true;
}

export function useSession(): SessionState {
  const [ready, setReady] = useState(false);
  const [connectionEpoch, setConnectionEpoch] = useState(0);
  const [providers, setProviders] = useState<Provider[]>([]);
  const [capabilities, setCapabilities] = useState<Record<string, ProviderCapabilities>>({});
  const [defaultCwd, setDefaultCwd] = useState("");
  const [ctrlJ, setCtrlJ] = useState<CtrlJMode>("newline");
  const [phase, setPhase] = useState<"composer" | "chat">(routedSessionId ? "chat" : "composer");
  const [session, setSession] = useState<SessionSummary | null>(null);
  const [blocks, setBlocks] = useState<Block[]>([]);
  const [options, setOptions] = useState<SessionOption[]>([]);
  const [actions, setActions] = useState<SessionActions>({});
  const [commands, setCommands] = useState<CommandGroup[]>([]);
  const [providerOptions, setProviderOptions] = useState<Record<string, SessionOption[]>>({});
  const [providerCommands, setProviderCommands] = useState<Record<string, CommandGroup[]>>({});
  const [filesByCwd, setFilesByCwd] = useState<Record<string, string[]>>({});
  const [cwdChecks, setCwdChecks] = useState<Record<string, { ok: boolean; message?: string }>>({});
  const [fileDiffs, setFileDiffs] = useState<Record<string, string>>({});
  const [lastError, setLastError] = useState("");
  const [forkPending, setForkPending] = useState(false);
  const wsRef = useRef<WebSocket | null>(null);
  const sessionIdRef = useRef<string | null>(routedSessionId);
  const pendingFileDiffKeysRef = useRef<Record<string, string[]>>({});
  const pendingStartRef = useRef<{
    requestId: string;
    key: string;
    provider: string;
    cwd: string;
    prompt: string;
    options?: Record<string, OptionValue>;
    queuedReplies: string[];
    failed?: boolean;
  } | null>(null);
  const pendingStartTimeoutRef = useRef<number | null>(null);
  const optimisticUsersRef = useRef<string[]>([]);

  const clearPendingStartTimeout = useCallback(() => {
    if (pendingStartTimeoutRef.current) window.clearTimeout(pendingStartTimeoutRef.current);
    pendingStartTimeoutRef.current = null;
  }, []);

  const failPendingStart = useCallback((message: string) => {
    const pending = pendingStartRef.current;
    if (!pending) return;
    clearPendingStartTimeout();
    pendingStartRef.current = null;
    restoreComposerDraft(sessionStorage, pending.prompt);
    history.replaceState(null, "", "/");
    document.title = "cmux agent";
    sessionIdRef.current = null;
    optimisticUsersRef.current = [];
    setSession(null);
    setBlocks([]);
    setOptions([]);
    setActions({});
    setCommands([]);
    pendingFileDiffKeysRef.current = {};
    setFileDiffs({});
    setLastError(message);
    setPhase("composer");
  }, [clearPendingStartTimeout]);

  const armPendingStartTimeout = useCallback(() => {
    clearPendingStartTimeout();
    pendingStartTimeoutRef.current = window.setTimeout(() => {
      failPendingStart("Failed to start agent: request timed out");
    }, PENDING_START_TIMEOUT_MS);
  }, [clearPendingStartTimeout, failPendingStart]);

  const sendRaw = useCallback((obj: unknown) => {
    const ws = wsRef.current;
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify(obj));
      return true;
    }
    return false;
  }, []);

  useEffect(() => {
    let closed = false;
    const connect = () => {
      const ws = new WebSocket((location.protocol === "https:" ? "wss://" : "ws://") + location.host + "/ws");
      wsRef.current = ws;
      ws.onopen = () => {
        const pending = pendingStartRef.current;
        if (sessionIdRef.current) sendRaw({ op: "subscribe", sessionId: sessionIdRef.current });
        else if (pending && !pending.failed) {
          sendRaw({ op: "start", requestId: pending.requestId, provider: pending.provider, cwd: pending.cwd, prompt: pending.prompt, options: pending.options });
          armPendingStartTimeout();
        }
      };
      ws.onmessage = (e) => {
        const msg = JSON.parse(e.data);
        switch (msg.kind) {
          case "hello": {
            const h = msg as Hello & { kind: string; capabilities?: Record<string, ProviderCapabilities> };
            setProviders(h.providers);
            setCapabilities(h.capabilities ?? {});
            setDefaultCwd(h.defaultCwd);
            setCtrlJ(h.keys?.ctrlJ === "menu" ? "menu" : "newline");
            setReady(true);
            setConnectionEpoch((n) => n + 1);
            break;
          }
          case "session-created":
            sessionIdRef.current = msg.session.id;
            history.replaceState(null, "", "/s/" + msg.session.id);
            document.title = msg.session.title || "cmux agent";
            if (msg.requestId && pendingStartRef.current?.requestId === msg.requestId) {
              const queuedReplies = pendingStartRef.current.queuedReplies;
              clearPendingStartTimeout();
              pendingStartRef.current = null;
              setSession({ ...msg.session, status: "running" });
              for (const prompt of queuedReplies) {
                sendRaw({ op: "send", sessionId: msg.session.id, prompt });
              }
            } else {
              setSession(msg.session);
              setBlocks([]);
              optimisticUsersRef.current = [];
            }
            setOptions([]);
            setActions({});
            setCommands([]);
            pendingFileDiffKeysRef.current = {};
            setFileDiffs({});
            setPhase("chat");
            break;
          case "history":
            sessionIdRef.current = msg.session.id;
            document.title = msg.session.title || "cmux agent";
            setSession(msg.session);
            setBlocks((msg.events as AgentEvent[]).reduce(foldEvent, [] as Block[]));
            optimisticUsersRef.current = [];
            setOptions(latestOptions(msg.events as AgentEvent[]));
            setActions(latestActions(msg.events as AgentEvent[]));
            setCommands(latestCommands(msg.events as AgentEvent[]));
            pendingFileDiffKeysRef.current = {};
            setFileDiffs({});
            setPhase("chat");
            break;
          case "no-session":
            history.replaceState(null, "", "/");
            sessionIdRef.current = null;
            setSession(null);
            setOptions([]);
            setActions({});
            setCommands([]);
            pendingFileDiffKeysRef.current = {};
            setFileDiffs({});
            setPhase("composer");
            optimisticUsersRef.current = [];
            break;
          case "session-status":
            if (msg.sessionId === sessionIdRef.current) {
              setSession((s) => (s ? { ...s, status: msg.status } : s));
            }
            break;
          case "event":
            if (msg.sessionId === sessionIdRef.current) {
              const evt = msg.evt as AgentEvent;
              if (evt.kind === "user" && consumeOptimisticUserEcho(optimisticUsersRef.current, evt.text)) {
                break;
              }
              setBlocks((bs) => foldEvent(bs, evt));
              if (evt.kind === "options") setOptions(evt.options);
              if (evt.kind === "options") setActions(evt.actions ?? {});
              if (evt.kind === "commands") setCommands((gs) => upsertCommands(gs, evt));
              if (evt.kind === "error") setForkPending(false);
            }
            break;
          case "session-forked":
            setForkPending(false);
            window.open("/s/" + msg.session.id, "_blank");
            break;
          case "options-list":
            setProviderOptions((m) => ({ ...m, [msg.provider]: msg.options ?? [] }));
            break;
          case "commands-list":
            setProviderCommands((m) => ({ ...m, [msg.provider]: msg.groups ?? [] }));
            break;
          case "files-list":
            setFilesByCwd((m) => ({ ...m, [msg.cwd]: msg.files ?? [] }));
            break;
          case "cwd-check":
            setCwdChecks((m) => ({ ...m, [msg.cwd]: { ok: Boolean(msg.ok), message: msg.message } }));
            break;
          case "file-diff":
            if (msg.sessionId === sessionIdRef.current) {
              const path = String(msg.path);
              const queue = pendingFileDiffKeysRef.current[path];
              const key = queue?.shift() ?? path;
              if (queue && !queue.length) delete pendingFileDiffKeysRef.current[path];
              setFileDiffs((m) => ({ ...m, [key]: String(msg.diff ?? "") }));
            }
            break;
          case "error":
            if (msg.op === "start") {
              const message = String(msg.message ?? "");
              const pending = pendingStartRef.current;
              if (pending && (!msg.requestId || msg.requestId === pending.requestId)) {
                failPendingStart(message);
              } else {
                setLastError(message);
              }
            }
            if (msg.op === "fork") setForkPending(false);
            if (msg.op === "get-file-diff" && typeof msg.path === "string" && msg.path) {
              const path = String(msg.path);
              const queue = pendingFileDiffKeysRef.current[path];
              const key = queue?.shift() ?? path;
              if (queue && !queue.length) delete pendingFileDiffKeysRef.current[path];
              setFileDiffs((m) => ({ ...m, [key]: String(msg.message ?? "Failed to load diff") }));
            }
            break;
        }
      };
      ws.onclose = () => { if (!closed) setTimeout(connect, 800); };
    };
    connect();
    return () => { closed = true; clearPendingStartTimeout(); wsRef.current?.close(); };
  }, [armPendingStartTimeout, clearPendingStartTimeout, failPendingStart, sendRaw]);

  const start = useCallback((opts: { provider: string; cwd: string; prompt: string; options?: Record<string, OptionValue> }) => {
    const key = JSON.stringify([opts.provider, opts.cwd, opts.prompt, opts.options ?? {}]);
    const current = pendingStartRef.current;
    if (current && !current.failed && current.key === key) return false;
    const requestId = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
    if (!sendRaw({ op: "start", requestId, ...opts })) return false;
    pendingStartRef.current = { requestId, key, queuedReplies: [], ...opts };
    armPendingStartTimeout();
    optimisticUsersRef.current = [opts.prompt];
    sessionIdRef.current = null;
    history.replaceState(null, "", "/");
    document.title = opts.prompt.length > 64 ? opts.prompt.slice(0, 64) + "…" : opts.prompt;
    setLastError("");
    setSession({
      id: `pending-${requestId}`,
      provider: opts.provider,
      cwd: opts.cwd,
      title: opts.prompt.length > 64 ? opts.prompt.slice(0, 64) + "…" : opts.prompt,
      status: "running",
    });
    setBlocks([{ kind: "user", text: opts.prompt }]);
    setOptions([]);
    setActions({});
    setCommands([]);
    pendingFileDiffKeysRef.current = {};
    setFileDiffs({});
    setPhase("chat");
    return true;
  }, [armPendingStartTimeout, sendRaw]);
  const compose = useCallback(() => {
    clearPendingStartTimeout();
    pendingStartRef.current = null;
    history.replaceState(null, "", "/");
    document.title = "cmux agent";
    sessionIdRef.current = null;
    setSession(null);
    setBlocks([]);
    setOptions([]);
    setActions({});
    setCommands([]);
    pendingFileDiffKeysRef.current = {};
    setFileDiffs({});
    setPhase("composer");
  }, [clearPendingStartTimeout]);
  const reply = useCallback((text: string) => {
    const pending = pendingStartRef.current;
    if (!sessionIdRef.current && pending?.failed) {
      start({ provider: pending.provider, cwd: pending.cwd, prompt: text, options: pending.options });
      return;
    }
    if (!sessionIdRef.current && pending && !pending.failed) {
      pending.queuedReplies.push(text);
      optimisticUsersRef.current.push(text);
      setBlocks((bs) => [...closeStreaming(bs), { kind: "user", text }]);
      return;
    }
    if (sessionIdRef.current) {
      if (sendRaw({ op: "send", sessionId: sessionIdRef.current, prompt: text })) {
        setSession((s) => (s ? { ...s, status: "running" } : s));
      }
    }
  }, [sendRaw, start]);
  const stop = useCallback(() => {
    if (sessionIdRef.current) sendRaw({ op: "stop", sessionId: sessionIdRef.current });
  }, [sendRaw]);
  const setOption = useCallback((id: string, value: OptionValue) => {
    if (sessionIdRef.current) sendRaw({ op: "set-option", sessionId: sessionIdRef.current, id, value });
  }, [sendRaw]);
  const fork = useCallback(() => {
    if (sessionIdRef.current) {
      if (sendRaw({ op: "fork", sessionId: sessionIdRef.current })) setForkPending(true);
    }
  }, [sendRaw]);
  const requestProviderOptions = useCallback((provider: string, cwd: string) => {
    sendRaw({ op: "list-options", provider, cwd });
  }, [sendRaw]);
  const requestProviderCommands = useCallback((provider: string, cwd: string) => {
    sendRaw({ op: "list-commands", provider, cwd });
  }, [sendRaw]);
  const requestFiles = useCallback((cwd: string, query?: string) => {
    sendRaw({ op: "list-files", cwd, query });
  }, [sendRaw]);
  const requestFileDiff = useCallback((sessionId: string, path: string) => {
    const request = decodeFileDiffRequest(path);
    if (sendRaw({ op: "get-file-diff", sessionId, path: request.path })) {
      pendingFileDiffKeysRef.current[request.path] = [...(pendingFileDiffKeysRef.current[request.path] ?? []), request.key];
    }
  }, [sendRaw]);
  const checkCwd = useCallback((cwd: string) => {
    sendRaw({ op: "check-cwd", cwd });
  }, [sendRaw]);
  const clearError = useCallback(() => setLastError(""), []);

  return {
    ready,
    connectionEpoch,
    providers,
    capabilities,
    defaultCwd,
    ctrlJ,
    phase,
    session,
    blocks,
    options,
    actions,
    commands,
    providerOptions,
    providerCommands,
    filesByCwd,
    cwdChecks,
    fileDiffs,
    lastError,
    forkPending,
    start,
    compose,
    reply,
    stop,
    setOption,
    fork,
    requestProviderOptions,
    requestProviderCommands,
    requestFiles,
    requestFileDiff,
    checkCwd,
    clearError,
  };
}

function latestOptions(events: AgentEvent[]): SessionOption[] {
  for (let i = events.length - 1; i >= 0; i--) {
    if (events[i].kind === "options") return (events[i] as Extract<AgentEvent, { kind: "options" }>).options;
  }
  return [];
}

function latestActions(events: AgentEvent[]): SessionActions {
  for (let i = events.length - 1; i >= 0; i--) {
    if (events[i].kind === "options") return (events[i] as Extract<AgentEvent, { kind: "options" }>).actions ?? {};
  }
  return {};
}

function latestCommands(events: AgentEvent[]): CommandGroup[] {
  return events.reduce((groups, evt) => evt.kind === "commands" ? upsertCommands(groups, evt) : groups, [] as CommandGroup[]);
}

function upsertCommands(groups: CommandGroup[], evt: Extract<AgentEvent, { kind: "commands" }>): CommandGroup[] {
  const next = groups.filter((g) => g.trigger !== evt.trigger);
  if (evt.commands.length) next.push({ trigger: evt.trigger, commands: evt.commands });
  return next;
}
