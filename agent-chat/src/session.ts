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
  | { kind: "error"; message: string };

export type OptionKind = "select" | "toggle";
export type OptionValue = string | boolean;
export type CommandTrigger = "/" | "$";
export interface OptionChoice { value: string; label: string; description?: string; }
export interface SessionOption {
  id: string;
  label: string;
  kind: OptionKind;
  value: OptionValue;
  role?: "effort" | "thinking-budget";
  choices?: OptionChoice[];
  disabled?: boolean;
  description?: string;
}
export interface CommandEntry { name: string; description?: string; source?: string; }
export interface CommandGroup { trigger: CommandTrigger; commands: CommandEntry[]; }
export interface ProviderCapabilities { options: SessionOption[]; triggers: CommandTrigger[]; }
export interface SessionActions { fork?: boolean; }

export type Block =
  | { kind: "user"; text: string }
  | { kind: "assistant"; text: string; open: boolean }
  | { kind: "thinking"; text: string; open: boolean }
  | { kind: "tool"; toolId: string; name: string; detail?: string; status: "running" | "ok" | "fail"; out?: string }
  | { kind: "status"; text: string }
  | { kind: "error"; text: string }
  | { kind: "footer"; text: string };

export interface Provider { id: string; label: string; iconUrl?: string; iconDarkUrl?: string; }
export interface SessionSummary { id: string; provider: string; cwd: string; title: string; status: string; capabilities?: ProviderCapabilities; }

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
    case "error":
      return [...closeStreaming(blocks), { kind: "error", text: evt.message }];
    case "status":
      return [...closeStreaming(blocks), { kind: "status", text: evt.text }];
    default:
      return blocks;
  }
}

interface Hello { providers: Provider[]; defaultCwd: string; }

export interface SessionState {
  ready: boolean;
  connectionEpoch: number;
  providers: Provider[];
  capabilities: Record<string, ProviderCapabilities>;
  defaultCwd: string;
  phase: "composer" | "chat";
  session: SessionSummary | null;
  blocks: Block[];
  options: SessionOption[];
  actions: SessionActions;
  commands: CommandGroup[];
  providerOptions: Record<string, SessionOption[]>;
  providerCommands: Record<string, CommandGroup[]>;
  start(opts: { provider: string; cwd: string; prompt: string; autoApprove: boolean; options?: Record<string, OptionValue> }): void;
  compose(): void;
  reply(text: string): void;
  stop(): void;
  setOption(id: string, value: OptionValue): void;
  fork(): void;
  requestProviderOptions(provider: string, cwd: string): void;
  requestProviderCommands(provider: string, cwd: string): void;
}

const routedSessionId = (location.pathname.match(/^\/s\/([\w-]+)/) || [])[1] || null;

export function useSession(): SessionState {
  const [ready, setReady] = useState(false);
  const [connectionEpoch, setConnectionEpoch] = useState(0);
  const [providers, setProviders] = useState<Provider[]>([]);
  const [capabilities, setCapabilities] = useState<Record<string, ProviderCapabilities>>({});
  const [defaultCwd, setDefaultCwd] = useState("");
  const [phase, setPhase] = useState<"composer" | "chat">(routedSessionId ? "chat" : "composer");
  const [session, setSession] = useState<SessionSummary | null>(null);
  const [blocks, setBlocks] = useState<Block[]>([]);
  const [options, setOptions] = useState<SessionOption[]>([]);
  const [actions, setActions] = useState<SessionActions>({});
  const [commands, setCommands] = useState<CommandGroup[]>([]);
  const [providerOptions, setProviderOptions] = useState<Record<string, SessionOption[]>>({});
  const [providerCommands, setProviderCommands] = useState<Record<string, CommandGroup[]>>({});
  const wsRef = useRef<WebSocket | null>(null);
  const sessionIdRef = useRef<string | null>(routedSessionId);

  const sendRaw = useCallback((obj: unknown) => {
    const ws = wsRef.current;
    if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj));
  }, []);

  useEffect(() => {
    let closed = false;
    const connect = () => {
      const ws = new WebSocket((location.protocol === "https:" ? "wss://" : "ws://") + location.host + "/ws");
      wsRef.current = ws;
      ws.onopen = () => {
        if (sessionIdRef.current) sendRaw({ op: "subscribe", sessionId: sessionIdRef.current });
      };
      ws.onmessage = (e) => {
        const msg = JSON.parse(e.data);
        switch (msg.kind) {
          case "hello": {
            const h = msg as Hello & { kind: string; capabilities?: Record<string, ProviderCapabilities> };
            setProviders(h.providers);
            setCapabilities(h.capabilities ?? {});
            setDefaultCwd(h.defaultCwd);
            setReady(true);
            setConnectionEpoch((n) => n + 1);
            break;
          }
          case "session-created":
            sessionIdRef.current = msg.session.id;
            history.replaceState(null, "", "/s/" + msg.session.id);
            document.title = msg.session.title || "cmux agent";
            setSession(msg.session);
            setBlocks([]);
            setOptions([]);
            setActions({});
            setCommands([]);
            setPhase("chat");
            break;
          case "history":
            sessionIdRef.current = msg.session.id;
            document.title = msg.session.title || "cmux agent";
            setSession(msg.session);
            setBlocks((msg.events as AgentEvent[]).reduce(foldEvent, [] as Block[]));
            setOptions(latestOptions(msg.events as AgentEvent[]));
            setActions(latestActions(msg.events as AgentEvent[]));
            setCommands(latestCommands(msg.events as AgentEvent[]));
            setPhase("chat");
            break;
          case "no-session":
            history.replaceState(null, "", "/");
            sessionIdRef.current = null;
            setSession(null);
            setOptions([]);
            setActions({});
            setCommands([]);
            setPhase("composer");
            break;
          case "session-status":
            if (msg.sessionId === sessionIdRef.current) {
              setSession((s) => (s ? { ...s, status: msg.status } : s));
            }
            break;
          case "event":
            if (msg.sessionId === sessionIdRef.current) {
              const evt = msg.evt as AgentEvent;
              setBlocks((bs) => foldEvent(bs, evt));
              if (evt.kind === "options") setOptions(evt.options);
              if (evt.kind === "options") setActions(evt.actions ?? {});
              if (evt.kind === "commands") setCommands((gs) => upsertCommands(gs, evt));
            }
            break;
          case "session-forked":
            window.open("/s/" + msg.session.id, "_blank");
            break;
          case "options-list":
            setProviderOptions((m) => ({ ...m, [msg.provider]: msg.options ?? [] }));
            break;
          case "commands-list":
            setProviderCommands((m) => ({ ...m, [msg.provider]: msg.groups ?? [] }));
            break;
        }
      };
      ws.onclose = () => { if (!closed) setTimeout(connect, 800); };
    };
    connect();
    return () => { closed = true; wsRef.current?.close(); };
  }, [sendRaw]);

  const start = useCallback((opts: { provider: string; cwd: string; prompt: string; autoApprove: boolean; options?: Record<string, OptionValue> }) => {
    sendRaw({ op: "start", ...opts });
  }, [sendRaw]);
  const compose = useCallback(() => {
    history.replaceState(null, "", "/");
    document.title = "cmux agent";
    sessionIdRef.current = null;
    setSession(null);
    setBlocks([]);
    setOptions([]);
    setActions({});
    setCommands([]);
    setPhase("composer");
  }, []);
  const reply = useCallback((text: string) => {
    if (sessionIdRef.current) sendRaw({ op: "send", sessionId: sessionIdRef.current, prompt: text });
  }, [sendRaw]);
  const stop = useCallback(() => {
    if (sessionIdRef.current) sendRaw({ op: "stop", sessionId: sessionIdRef.current });
  }, [sendRaw]);
  const setOption = useCallback((id: string, value: OptionValue) => {
    if (sessionIdRef.current) sendRaw({ op: "set-option", sessionId: sessionIdRef.current, id, value });
  }, [sendRaw]);
  const fork = useCallback(() => {
    if (sessionIdRef.current) sendRaw({ op: "fork", sessionId: sessionIdRef.current });
  }, [sendRaw]);
  const requestProviderOptions = useCallback((provider: string, cwd: string) => {
    sendRaw({ op: "list-options", provider, cwd });
  }, [sendRaw]);
  const requestProviderCommands = useCallback((provider: string, cwd: string) => {
    sendRaw({ op: "list-commands", provider, cwd });
  }, [sendRaw]);

  return {
    ready,
    connectionEpoch,
    providers,
    capabilities,
    defaultCwd,
    phase,
    session,
    blocks,
    options,
    actions,
    commands,
    providerOptions,
    providerCommands,
    start,
    compose,
    reply,
    stop,
    setOption,
    fork,
    requestProviderOptions,
    requestProviderCommands,
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
