// Client-side session state: one WebSocket, one session per page.
import { useCallback, useEffect, useRef, useState } from "react";
import { applyThemeVars } from "./theme";
import { openSessionConnection } from "./connection";
import type { HarnessRecommendation, HarnessCatalogs } from "../harness-contract";
import { latestRouteStatus, normalizeRouteStatus, type RouteHealth, type RoutePhase, type RouteStatus } from "../route-status";

export type AgentEvent =
  | { kind: "meta"; model?: string; providerSessionId?: string }
  | {
      kind: "routing";
      phase: RoutePhase;
      conversationId: string;
      requestId: string;
      attempt: number;
      parentSessionId?: string;
      parentConversationId?: string;
      provider?: string;
      model?: string;
      reason?: string;
      handoffMode?: "native_fork" | "compact_replay";
      retryAfterMs?: number;
      health?: RouteHealth;
      at?: number;
    }
  | { kind: "options"; options: SessionOption[]; actions?: SessionActions }
  | { kind: "commands"; trigger: CommandTrigger; commands: CommandEntry[] }
  | { kind: "user"; text: string }
  | { kind: "status"; text: string }
  | { kind: "plan"; entries: AgentPlanEntry[] }
  | { kind: "delta"; text: string }
  | { kind: "assistant"; text: string }
  | { kind: "thinking"; text: string }
  | { kind: "tool-start"; toolId: string; name: string; detail?: string }
  | { kind: "tool-end"; toolId: string; name?: string; detail?: string; ok?: boolean }
  | { kind: "done"; stats?: string }
  | { kind: "files-changed"; files: ChangedFile[] }
  | { kind: "error"; message: string; prompt?: string };

export type OptionKind = "select" | "toggle";
export type OptionValue = string | boolean;
export type CommandTrigger = "/" | "$" | "@";
export interface OptionChoice {
  value: string;
  label: string;
  description?: string;
  disabled?: boolean;
  disabledReason?: string;
  efforts?: OptionChoice[];
  defaultEffort?: string;
}
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
export interface SessionActions { fork?: boolean; handoff?: boolean; }
export interface ChangedFile { path: string; adds: number; dels: number; status: string; }
export type AgentPlanStatus = "pending" | "in_progress" | "completed" | "unknown";
export interface AgentPlanEntry { text: string; status: AgentPlanStatus; priority?: string; }

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
  | { kind: "plan"; entries: AgentPlanEntry[] }
  | { kind: "error"; text: string }
  | { kind: "footer"; text: string }
  | { kind: "files"; files: ChangedFile[]; revision?: string };

export interface Provider { id: string; label: string; iconUrl?: string; iconDarkUrl?: string; installed?: boolean; installCommand?: string; }
export type { HarnessRecommendation } from "../harness-contract";

export interface CwdHarnessRequest {
  requestId: string;
  cwd: string;
  connectionEpoch: number;
}

export interface CwdHarnessResponse {
  requestId?: unknown;
  cwd?: unknown;
  connectionEpoch?: unknown;
}

/** Only the latest request on the current WebSocket may update visible harnesses. */
export function acceptsCwdHarnessResponse(
  active: CwdHarnessRequest | null,
  response: CwdHarnessResponse,
): boolean {
  return Boolean(
    active
    && response.requestId === active.requestId
    && response.cwd === active.cwd
    && response.connectionEpoch === active.connectionEpoch,
  );
}

/** Harness recommendations and the cwd they were discovered for. */
export interface HarnessSnapshot {
  cwd: string;
  harnesses: HarnessRecommendation[];
}

const EMPTY_HARNESS_SNAPSHOT: HarnessSnapshot = { cwd: "", harnesses: [] };

/** The server discovers hello harnesses for the default cwd it also sends. */
export function helloHarnessSnapshot(hello: { defaultCwd: string; harnesses?: HarnessRecommendation[] }): HarnessSnapshot {
  return { cwd: hello.defaultCwd, harnesses: hello.harnesses ?? [] };
}

/** Keep recommendations already known for the checked cwd; drop any for another cwd. */
export function harnessSnapshotForCwdCheck(current: HarnessSnapshot, cwd: string): HarnessSnapshot {
  return current.cwd === cwd ? current : EMPTY_HARNESS_SNAPSHOT;
}

export function visibleWorkflowHarnesses(snapshot: HarnessSnapshot, cwd: string): HarnessRecommendation[] {
  if (!cwd || snapshot.cwd !== cwd) return [];
  return snapshot.harnesses.filter((h) => h.kind === "workflow" && h.installed).slice(0, 2);
}

export interface SessionSummary {
  id: string;
  provider: string;
  cwd: string;
  title: string;
  status: string;
  capabilities?: ProviderCapabilities;
  conversationId?: string;
  parentSessionId?: string;
  parentConversationId?: string;
  startRequestId?: string;
  /** "transcript": a chat view of an agent running in a cmux terminal. */
  mode?: "transcript";
  /** What that agent is waiting on in the terminal (permission, question). */
  attention?: string | null;
}
export type CtrlJMode = "newline" | "menu";

function closeStreaming(blocks: Block[]): Block[] {
  const last = blocks[blocks.length - 1];
  if (last && (last.kind === "assistant" || last.kind === "thinking") && last.open) {
    return [...blocks.slice(0, -1), { ...last, open: false }];
  }
  return blocks;
}

class EventFolder {
  private owned = false;
  private tools: Map<string, number[]> | null = null;
  private filesCount: number | undefined;
  private planIndex: number | null | undefined;

  constructor(public blocks: Block[], private indexed: boolean) {}

  private writable(): Block[] {
    if (!this.owned) {
      this.blocks = this.blocks.slice();
      this.owned = true;
    }
    return this.blocks;
  }

  private closeStreaming(): void {
    const last = this.blocks[this.blocks.length - 1];
    if (last && (last.kind === "assistant" || last.kind === "thinking") && last.open) {
      this.writable()[this.blocks.length - 1] = { ...last, open: false };
    }
  }

  private push(block: Block): void {
    this.closeStreaming();
    this.writable().push(block);
  }

  fold(evt: AgentEvent): void {
    const last = this.blocks[this.blocks.length - 1];
    switch (evt.kind) {
      case "user":
        this.push({ kind: "user", text: evt.text });
        this.planIndex = null;
        break;
      case "delta":
      case "assistant":
      case "thinking": {
        const kind = evt.kind === "thinking" ? "thinking" : "assistant";
        if (last && last.kind === kind && last.open) {
          this.writable()[this.blocks.length - 1] = {
            ...last, text: evt.kind === "assistant" ? evt.text : last.text + evt.text,
            open: evt.kind !== "assistant",
          };
        } else {
          this.push({ kind, text: evt.text, open: evt.kind !== "assistant" });
        }
        break;
      }
      case "tool-start": {
        const index = this.blocks.length;
        this.push({ kind: "tool", toolId: evt.toolId, name: evt.name || "tool", detail: evt.detail, status: "running" });
        if (this.tools) {
          const indices = this.tools.get(evt.toolId) ?? [];
          indices.push(index);
          this.tools.set(evt.toolId, indices);
        }
        break;
      }
      case "tool-end": {
        const blocks = this.writable();
        const complete = (index: number) => {
          const block = blocks[index] as Extract<Block, { kind: "tool" }>;
          blocks[index] = { ...block, status: evt.ok === false ? "fail" : "ok", out: evt.detail || block.out };
        };
        if (this.indexed) {
          if (!this.tools) {
            this.tools = new Map();
            for (let index = 0; index < blocks.length; index++) {
              const block = blocks[index];
              if (block.kind !== "tool") continue;
              const indices = this.tools.get(block.toolId) ?? [];
              indices.push(index);
              this.tools.set(block.toolId, indices);
            }
          }
          for (const index of this.tools.get(evt.toolId) ?? []) complete(index);
        } else {
          for (let index = 0; index < blocks.length; index++) {
            const block = blocks[index];
            if (block.kind === "tool" && block.toolId === evt.toolId) complete(index);
          }
        }
        break;
      }
      case "done":
        this.push({ kind: "footer", text: evt.stats ?? "" });
        break;
      case "files-changed": {
        let revision: string;
        if (this.indexed) {
          this.filesCount ??= this.blocks.reduce((count, block) => count + Number(block.kind === "files"), 0);
          revision = String(++this.filesCount);
        } else revision = nextFilesRevision(this.blocks);
        this.push({ kind: "files", files: evt.files, revision });
        break;
      }
      case "error":
        this.push({ kind: "error", text: evt.message });
        break;
      case "status":
        this.push({ kind: "status", text: evt.text });
        break;
      case "plan": {
        this.closeStreaming();
        if (this.planIndex === undefined) {
          let start = 0;
          for (let index = this.blocks.length - 1; index >= 0; index--) {
            if (this.blocks[index].kind === "user") { start = index + 1; break; }
          }
          this.planIndex = null;
          for (let index = start; index < this.blocks.length; index++) {
            if (this.blocks[index].kind === "plan") { this.planIndex = index; break; }
          }
        }
        const plan = { kind: "plan" as const, entries: evt.entries };
        if (this.planIndex === null) {
          this.planIndex = this.blocks.length;
          this.writable().push(plan);
        } else this.writable()[this.planIndex] = plan;
        break;
      }
    }
  }
}

export function foldEvent(blocks: Block[], evt: AgentEvent): Block[] {
  const folder = new EventFolder(blocks, false);
  folder.fold(evt);
  return folder.blocks;
}

/** Replay into one owned array; indexes live only for this batch. */
export function foldEvents(blocks: Block[], events: AgentEvent[]): Block[] {
  const folder = new EventFolder(blocks, true);
  for (const event of events) folder.fold(event);
  return folder.blocks;
}

interface Hello { providers: Provider[]; harnesses?: HarnessRecommendation[]; harnessCatalogs?: HarnessCatalogs; defaultCwd: string; keys?: { ctrlJ?: CtrlJMode }; }

export interface SessionState {
  ready: boolean;
  connectionEpoch: number;
  providers: Provider[];
  harnessSnapshot: HarnessSnapshot;
  harnessCatalogs: HarnessCatalogs;
  capabilities: Record<string, ProviderCapabilities>;
  defaultCwd: string;
  ctrlJ: CtrlJMode;
  phase: "composer" | "chat";
  session: SessionSummary | null;
  routing: RouteStatus | null;
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
  handoffPending: boolean;
  start(opts: { provider: string; cwd: string; prompt: string; options?: Record<string, OptionValue> }): boolean;
  compose(): void;
  reply(text: string): void;
  stop(): void;
  /** Focuses the terminal pane behind a terminal chat view. */
  focusTerminal(): void;
  setOption(id: string, value: OptionValue): void;
  fork(): void;
  handoff(): void;
  requestProviderOptions(provider: string, cwd: string): void;
  requestProviderCommands(provider: string, cwd: string): void;
  requestFiles(cwd: string, query?: string): void;
  requestFileDiff(sessionId: string, path: string): void;
  checkCwd(cwd: string): void;
  clearError(): void;
}

declare global {
  interface Window { __AGENT_CHAT_BASE__?: string }
}

function basePrefix(): string {
  const base = typeof window === "undefined" ? "" : window.__AGENT_CHAT_BASE__ ?? "";
  return base && base !== "/" ? base.replace(/\/$/, "") : "";
}

function routePath(): string {
  if (typeof location === "undefined") return "/";
  const base = basePrefix();
  if (!base) return location.pathname;
  // Bare /<token> (no trailing slash) is the app root.
  if (location.pathname === base) return "/";
  return location.pathname.startsWith(base + "/") ? location.pathname.slice(base.length) : location.pathname;
}

function appPath(path: string): string {
  return `${basePrefix()}${path}`;
}

const routedSessionId = (routePath().match(/^\/s\/([\w-]+)/) || [])[1] || null;
/** Transcript views use `t-<agent session id>`; known before history arrives. */
export const routedToTranscript = routedSessionId?.startsWith("t-") ?? false;
export const composerDraftKey = "agentui.draft";
const PENDING_START_TIMEOUT_MS = 30_000;

function newClientRequestId(prefix: string): string {
  return `${prefix}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
}

export function restoreComposerDraft(storage: Pick<Storage, "setItem">, prompt: string) {
  storage.setItem(composerDraftKey, prompt);
}

// An echo matches anywhere in the queue: one that never lands (a failed send)
// or lands rewritten (`!ls` recorded as a bash input) must not block the rest.
export function consumeOptimisticUserEcho(queue: string[], text: string): boolean {
  const index = queue.indexOf(text);
  if (index < 0) return false;
  queue.splice(index, 1);
  return true;
}

export function shouldAcceptSessionActionResponse(
  sourceSessionId: string | undefined,
  pendingSourceSessionId: string | null,
  currentSessionId: string | null,
): boolean {
  return Boolean(
    sourceSessionId
      && sourceSessionId === pendingSourceSessionId
      && sourceSessionId === currentSessionId
  );
}

export function useSession(): SessionState {
  const [ready, setReady] = useState(false);
  const [connectionEpoch, setConnectionEpoch] = useState(0);
  const [providers, setProviders] = useState<Provider[]>([]);
  const [harnessSnapshot, setHarnessSnapshot] = useState<HarnessSnapshot>(EMPTY_HARNESS_SNAPSHOT);
  const [harnessCatalogs, setHarnessCatalogs] = useState<HarnessCatalogs>({});
  const [capabilities, setCapabilities] = useState<Record<string, ProviderCapabilities>>({});
  const [defaultCwd, setDefaultCwd] = useState("");
  const [ctrlJ, setCtrlJ] = useState<CtrlJMode>("newline");
  const [phase, setPhase] = useState<"composer" | "chat">(routedSessionId ? "chat" : "composer");
  const [session, setSession] = useState<SessionSummary | null>(null);
  const [routing, setRouting] = useState<RouteStatus | null>(null);
  const [blocks, setBlocks] = useState<Block[]>([]);
  const streamEventsRef = useRef<AgentEvent[]>([]);
  const streamTimerRef = useRef<number | null>(null);
  const streamGenerationRef = useRef(0);
  const discardStream = useCallback(() => {
    if (streamTimerRef.current !== null) window.clearTimeout(streamTimerRef.current);
    streamTimerRef.current = null;
    streamEventsRef.current = [];
    streamGenerationRef.current++;
  }, []);
  const flushStream = useCallback((boundary?: AgentEvent) => {
    const events = streamEventsRef.current;
    discardStream();
    if (boundary) events.push(boundary);
    if (!events.length) return;
    setBlocks((bs) => events.length === 1 ? foldEvent(bs, events[0]!) : foldEvents(bs, events));
  }, [discardStream]);
  const queueStream = useCallback((evt: AgentEvent) => {
    streamEventsRef.current.push(evt);
    if (streamTimerRef.current !== null) return;
    const generation = streamGenerationRef.current;
    // A timer also runs in background tabs, where animation frames may stop.
    streamTimerRef.current = window.setTimeout(() => {
      if (streamGenerationRef.current === generation) flushStream();
    }, 16);
  }, [flushStream]);
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
  const [handoffPending, setHandoffPending] = useState(false);
  // Reserve the tab during the click's user-activation window. The provider
  // fork itself is asynchronous, so opening it when the response arrives can
  // be rejected as a popup by the browser.
  const handoffWindowRef = useRef<Window | null>(null);
  const pendingHandoffSourceSessionRef = useRef<string | null>(null);
  const pendingHandoffRequestRef = useRef<string | null>(null);
  const forkWindowRef = useRef<Window | null>(null);
  const pendingForkSourceSessionRef = useRef<string | null>(null);
  const pendingForkRequestRef = useRef<string | null>(null);
  const wsRef = useRef<WebSocket | null>(null);
  const sessionIdRef = useRef<string | null>(routedSessionId);
  const pendingFileDiffKeysRef = useRef<Record<string, string[]>>({});
  const pendingStartRef = useRef<{
    requestId: string;
    conversationId: string;
    key: string;
    provider: string;
    cwd: string;
    prompt: string;
    options?: Record<string, OptionValue>;
    queuedReplies: { requestId: string; prompt: string }[];
    failed?: boolean;
  } | null>(null);
  const pendingStartTimeoutRef = useRef<number | null>(null);
  const optimisticUsersRef = useRef<string[]>([]);
  // The last status the server sent: reply() shows "running" before the server
  // knows, and a send that fails puts this back.
  const serverStatusRef = useRef<string | null>(null);
  const sessionModeRef = useRef<SessionSummary["mode"]>(routedToTranscript ? "transcript" : undefined);
  useEffect(() => {
    if (session) sessionModeRef.current = session.mode;
  }, [session]);
  const latestCwdRequestRef = useRef<CwdHarnessRequest | null>(null);

  const closeHandoffWindow = useCallback(() => {
    const popup = handoffWindowRef.current;
    handoffWindowRef.current = null;
    pendingHandoffSourceSessionRef.current = null;
    pendingHandoffRequestRef.current = null;
    if (popup && !popup.closed) popup.close();
  }, []);

  const closeForkWindow = useCallback(() => {
    const popup = forkWindowRef.current;
    forkWindowRef.current = null;
    pendingForkSourceSessionRef.current = null;
    pendingForkRequestRef.current = null;
    if (popup && !popup.closed) popup.close();
  }, []);

  const resetSessionActions = useCallback(() => {
    closeForkWindow();
    closeHandoffWindow();
    setForkPending(false);
    setHandoffPending(false);
  }, [closeForkWindow, closeHandoffWindow]);

  const clearPendingStartTimeout = useCallback(() => {
    if (pendingStartTimeoutRef.current) window.clearTimeout(pendingStartTimeoutRef.current);
    pendingStartTimeoutRef.current = null;
  }, []);

  const failPendingStart = useCallback((message: string) => {
    const pending = pendingStartRef.current;
    if (!pending) return;
    discardStream();
    clearPendingStartTimeout();
    pendingStartRef.current = null;
    restoreComposerDraft(sessionStorage, pending.prompt);
    history.replaceState(null, "", appPath("/"));
    document.title = "cmux agent";
    sessionIdRef.current = null;
    optimisticUsersRef.current = [];
    setSession(null);
    setRouting(null);
    setBlocks([]);
    setOptions([]);
    setActions({});
    setCommands([]);
    pendingFileDiffKeysRef.current = {};
    setFileDiffs({});
    setLastError(message);
    setPhase("composer");
  }, [clearPendingStartTimeout, discardStream]);

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
    const disconnect = openSessionConnection({
      createSocket: () => new WebSocket((location.protocol === "https:" ? "wss://" : "ws://") + location.host + appPath("/ws")),
      onSocket: (ws) => {
        wsRef.current = ws;
        if (!ws) flushStream();
      },
      onOpen: () => {
        const pending = pendingStartRef.current;
        if (sessionIdRef.current) sendRaw({ op: "subscribe", sessionId: sessionIdRef.current });
        else if (pending && !pending.failed) {
          sendRaw({ op: "start", requestId: pending.requestId, conversationId: pending.conversationId, provider: pending.provider, cwd: pending.cwd, prompt: pending.prompt, options: pending.options });
          armPendingStartTimeout();
        }
        if (sessionIdRef.current && pendingForkSourceSessionRef.current === sessionIdRef.current && pendingForkRequestRef.current) {
          sendRaw({ op: "fork", sessionId: sessionIdRef.current, requestId: pendingForkRequestRef.current });
        }
        if (sessionIdRef.current && pendingHandoffSourceSessionRef.current === sessionIdRef.current && pendingHandoffRequestRef.current) {
          sendRaw({ op: "handoff", sessionId: sessionIdRef.current, requestId: pendingHandoffRequestRef.current });
        }
      },
      onMessage: (e) => {
        const msg = JSON.parse(e.data);
        switch (msg.kind) {
          case "hello": {
            const h = msg as Hello & { kind: string; capabilities?: Record<string, ProviderCapabilities> };
            setProviders(h.providers);
            setHarnessCatalogs(h.harnessCatalogs ?? {});
            latestCwdRequestRef.current = null;
            setHarnessSnapshot(helloHarnessSnapshot(h));
            setCapabilities(h.capabilities ?? {});
            setDefaultCwd(h.defaultCwd);
            setCtrlJ(h.keys?.ctrlJ === "menu" ? "menu" : "newline");
            setReady(true);
            setConnectionEpoch((n) => n + 1);
            break;
          }
          case "session-created": {
            const pending = pendingStartRef.current;
            if (!pending || msg.requestId !== pending.requestId) {
              // A timed-out or superseded start may still subscribe this
              // socket on the server. Keep the current UI and restore its
              // subscription rather than accepting that late selection.
              const currentSessionId = sessionIdRef.current;
              if (currentSessionId && currentSessionId !== msg.session.id) {
                sendRaw({ op: "subscribe", sessionId: currentSessionId });
              }
              break;
            }
            if (sessionIdRef.current !== msg.session.id) resetSessionActions();
            discardStream();
            sessionIdRef.current = msg.session.id;
            history.replaceState(null, "", appPath("/s/" + msg.session.id));
            document.title = msg.session.title || "cmux agent";
            const queuedReplies = pending.queuedReplies;
            clearPendingStartTimeout();
            pendingStartRef.current = null;
            setSession({ ...msg.session, status: "running" });
            setRouting(msg.routing?.kind === "routing" ? normalizeRouteStatus(msg.routing) : null);
            for (const queued of queuedReplies) {
              sendRaw({ op: "send", sessionId: msg.session.id, requestId: queued.requestId, prompt: queued.prompt });
            }
            setOptions([]);
            setActions({});
            setCommands([]);
            pendingFileDiffKeysRef.current = {};
            setFileDiffs({});
            setPhase("chat");
            break;
          }
          case "history":
            if (msg.sessionId !== sessionIdRef.current) break;
            discardStream();
            if (sessionIdRef.current !== msg.session.id) resetSessionActions();
            sessionIdRef.current = msg.session.id;
            document.title = msg.session.title || "cmux agent";
            serverStatusRef.current = msg.session.status;
            setSession(msg.session);
            setRouting(latestRouteStatus(msg.events as AgentEvent[]));
            setBlocks(foldEvents([], msg.events as AgentEvent[]));
            optimisticUsersRef.current = [];
            setOptions(latestOptions(msg.events as AgentEvent[]));
            setActions(latestActions(msg.events as AgentEvent[]));
            setCommands(latestCommands(msg.events as AgentEvent[]));
            pendingFileDiffKeysRef.current = {};
            setFileDiffs({});
            setPhase("chat");
            break;
          case "no-session":
            if (!sessionIdRef.current || msg.sessionId !== sessionIdRef.current) break;
            resetSessionActions();
            discardStream();
            history.replaceState(null, "", appPath("/"));
            sessionIdRef.current = null;
            setSession(null);
            setRouting(null);
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
              flushStream();
              serverStatusRef.current = msg.status;
              setSession((s) => (s ? { ...s, status: msg.status } : s));
            }
            break;
          case "session-attention":
            if (msg.sessionId === sessionIdRef.current) {
              flushStream();
              setSession((s) => (s ? { ...s, attention: typeof msg.attention === "string" ? msg.attention : null } : s));
            }
            break;
          case "session-title":
            if (msg.sessionId === sessionIdRef.current && typeof msg.title === "string") {
              document.title = msg.title || "cmux agent";
              setSession((s) => (s ? { ...s, title: msg.title } : s));
            }
            break;
          case "event":
            if (msg.sessionId === sessionIdRef.current) {
              const evt = msg.evt as AgentEvent;
              if (evt.kind === "routing") setRouting(normalizeRouteStatus(evt));
              if (evt.kind === "user" && consumeOptimisticUserEcho(optimisticUsersRef.current, evt.text)) {
                flushStream();
                break;
              }
              if (evt.kind === "delta" || evt.kind === "thinking") queueStream(evt);
              else flushStream(evt);
              if (evt.kind === "options") setOptions(evt.options);
              if (evt.kind === "options") setActions(evt.actions ?? {});
              if (evt.kind === "commands") setCommands((gs) => upsertCommands(gs, evt));
              if (evt.kind === "error" && evt.prompt !== undefined) {
                // The prompt never reached the terminal: its echo will not
                // come, and the agent is as busy as the server last said.
                consumeOptimisticUserEcho(optimisticUsersRef.current, evt.prompt);
                const status = serverStatusRef.current ?? "idle";
                setSession((s) => (s ? { ...s, status } : s));
              }
            }
            break;
          case "session-forked": {
            if (!shouldAcceptSessionActionResponse(
              msg.session?.parentSessionId,
              pendingForkSourceSessionRef.current,
              sessionIdRef.current,
            )) break;
            if (msg.requestId && msg.requestId !== pendingForkRequestRef.current) break;
            setForkPending(false);
            const target = appPath("/s/" + msg.session.id);
            const popup = forkWindowRef.current;
            forkWindowRef.current = null;
            pendingForkSourceSessionRef.current = null;
            pendingForkRequestRef.current = null;
            if (popup && !popup.closed) {
              popup.location.href = target;
              popup.focus();
            } else {
              window.location.assign(target);
            }
            break;
          }
          case "session-handoff":
            {
              const sourceSessionId = typeof msg.sourceSessionId === "string"
                ? msg.sourceSessionId
                : undefined;
              if (!shouldAcceptSessionActionResponse(
                sourceSessionId,
                pendingHandoffSourceSessionRef.current,
                sessionIdRef.current,
              )) {
                break;
              }
              if (msg.requestId && msg.requestId !== pendingHandoffRequestRef.current) break;
              setHandoffPending(false);
              const target = appPath("/s/" + msg.session.id);
              const popup = handoffWindowRef.current;
              handoffWindowRef.current = null;
              pendingHandoffSourceSessionRef.current = null;
              pendingHandoffRequestRef.current = null;
              if (popup && !popup.closed) {
                popup.location.href = target;
                popup.focus();
              } else {
                // A popup blocker (or a non-browser host) still leaves the
                // user with a deterministic way to reach the child session.
                window.location.assign(target);
              }
            }
            break;
          case "options-list":
            setProviderOptions((m) => ({ ...m, [msg.provider]: msg.options ?? [] }));
            break;
          case "model-catalog":
            if (msg.options && typeof msg.options === "object") {
              setProviderOptions((current) => ({ ...current, ...msg.options }));
            }
            break;
          case "commands-list":
            setProviderCommands((m) => ({ ...m, [msg.provider]: msg.groups ?? [] }));
            break;
          case "files-list":
            setFilesByCwd((m) => ({ ...m, [msg.cwd]: msg.files ?? [] }));
            break;
          case "cwd-check":
            setCwdChecks((m) => ({ ...m, [msg.cwd]: { ok: Boolean(msg.ok), message: msg.message } }));
            if (Array.isArray(msg.harnesses) && acceptsCwdHarnessResponse(latestCwdRequestRef.current, msg)) {
              setHarnessSnapshot({ cwd: String(msg.cwd), harnesses: msg.harnesses as HarnessRecommendation[] });
            }
            break;
          case "theme":
            if (msg.vars && typeof msg.vars === "object") applyThemeVars(msg.vars, msg.theme);
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
              if (pending && msg.requestId === pending.requestId) {
                failPendingStart(message);
              }
            }
            if (msg.op === "fork" && shouldAcceptSessionActionResponse(msg.sessionId, pendingForkSourceSessionRef.current, sessionIdRef.current)) {
              closeForkWindow();
              setForkPending(false);
            }
            if (msg.op === "handoff" && shouldAcceptSessionActionResponse(msg.sessionId, pendingHandoffSourceSessionRef.current, sessionIdRef.current)) {
              closeHandoffWindow();
              setHandoffPending(false);
            }
            if (msg.op === "get-file-diff" && typeof msg.path === "string" && msg.path) {
              const path = String(msg.path);
              const queue = pendingFileDiffKeysRef.current[path];
              const key = queue?.shift() ?? path;
              if (queue && !queue.length) delete pendingFileDiffKeysRef.current[path];
              setFileDiffs((m) => ({ ...m, [key]: String(msg.message ?? "Failed to load diff") }));
            }
            break;
        }
      },
    });
    return () => {
      discardStream();
      disconnect();
      clearPendingStartTimeout();
      resetSessionActions();
    };
  }, [armPendingStartTimeout, clearPendingStartTimeout, closeForkWindow, closeHandoffWindow, discardStream, failPendingStart, flushStream, queueStream, resetSessionActions, sendRaw]);

  const start = useCallback((opts: { provider: string; cwd: string; prompt: string; options?: Record<string, OptionValue> }) => {
    const key = JSON.stringify([opts.provider, opts.cwd, opts.prompt, opts.options ?? {}]);
    const current = pendingStartRef.current;
    if (current && !current.failed && current.key === key) return false;
    const requestId = newClientRequestId("start");
    const conversationId = crypto.randomUUID();
    if (!sendRaw({ op: "start", requestId, conversationId, ...opts })) return false;
            resetSessionActions();
            discardStream();
    pendingStartRef.current = { requestId, conversationId, key, queuedReplies: [], ...opts };
    armPendingStartTimeout();
    optimisticUsersRef.current = [opts.prompt];
    sessionIdRef.current = null;
    history.replaceState(null, "", appPath("/"));
    document.title = opts.prompt.length > 64 ? opts.prompt.slice(0, 64) + "…" : opts.prompt;
    setLastError("");
    setSession({
      id: `pending-${requestId}`,
      provider: opts.provider,
      cwd: opts.cwd,
      title: opts.prompt.length > 64 ? opts.prompt.slice(0, 64) + "…" : opts.prompt,
      status: "running",
      conversationId,
      startRequestId: requestId,
    });
    setRouting(null);
    setBlocks([{ kind: "user", text: opts.prompt }]);
    setOptions([]);
    setActions({});
    setCommands([]);
    pendingFileDiffKeysRef.current = {};
    setFileDiffs({});
    setPhase("chat");
    return true;
  }, [armPendingStartTimeout, discardStream, resetSessionActions, sendRaw]);
  const compose = useCallback(() => {
    discardStream();
    clearPendingStartTimeout();
    resetSessionActions();
    pendingStartRef.current = null;
    history.replaceState(null, "", appPath("/"));
    document.title = "cmux agent";
    sessionIdRef.current = null;
    setRouting(null);
    setSession(null);
    setBlocks([]);
    setOptions([]);
    setActions({});
    setCommands([]);
    pendingFileDiffKeysRef.current = {};
    setFileDiffs({});
    setPhase("composer");
  }, [clearPendingStartTimeout, discardStream, resetSessionActions]);
  const reply = useCallback((text: string) => {
    const pending = pendingStartRef.current;
    if (!sessionIdRef.current && pending?.failed) {
      start({ provider: pending.provider, cwd: pending.cwd, prompt: text, options: pending.options });
      return;
    }
    if (!sessionIdRef.current && pending && !pending.failed) {
      flushStream();
      pending.queuedReplies.push({ requestId: newClientRequestId("turn"), prompt: text });
      optimisticUsersRef.current.push(text);
      setBlocks((bs) => [...closeStreaming(bs), { kind: "user", text }]);
      return;
    }
    if (sessionIdRef.current) {
      if (sendRaw({ op: "send", sessionId: sessionIdRef.current, requestId: newClientRequestId("turn"), prompt: text })) {
        setSession((s) => (s ? { ...s, status: "running" } : s));
        // A terminal view's prompt only reaches the event log when the agent's
        // transcript records it; show it now and drop that echo when it lands.
        if (sessionModeRef.current === "transcript") {
          flushStream();
          optimisticUsersRef.current.push(text);
          setBlocks((bs) => [...closeStreaming(bs), { kind: "user", text }]);
        }
      }
    }
  }, [flushStream, sendRaw, start]);
  const focusTerminal = useCallback(() => {
    if (sessionIdRef.current) sendRaw({ op: "focus-terminal", sessionId: sessionIdRef.current });
  }, [sendRaw]);
  const stop = useCallback(() => {
    flushStream();
    if (sessionIdRef.current) sendRaw({ op: "stop", sessionId: sessionIdRef.current });
  }, [flushStream, sendRaw]);
  const setOption = useCallback((id: string, value: OptionValue) => {
    if (sessionIdRef.current) sendRaw({ op: "set-option", sessionId: sessionIdRef.current, id, value });
  }, [sendRaw]);
  const fork = useCallback(() => {
    const sourceSessionId = sessionIdRef.current;
    if (sourceSessionId && !pendingForkSourceSessionRef.current) {
      const popup = window.open("about:blank", "_blank");
      const requestId = newClientRequestId("fork");
      forkWindowRef.current = popup;
      pendingForkSourceSessionRef.current = sourceSessionId;
      pendingForkRequestRef.current = requestId;
      if (sendRaw({ op: "fork", sessionId: sourceSessionId, requestId })) {
        setForkPending(true);
      } else {
        closeForkWindow();
      }
    }
  }, [closeForkWindow, sendRaw]);
  const handoff = useCallback(() => {
    const sourceSessionId = sessionIdRef.current;
    if (sourceSessionId && !pendingHandoffSourceSessionRef.current) {
      closeHandoffWindow();
      const popup = window.open("about:blank", "_blank");
      const requestId = newClientRequestId("handoff");
      handoffWindowRef.current = popup;
      pendingHandoffSourceSessionRef.current = sourceSessionId;
      pendingHandoffRequestRef.current = requestId;
      if (sendRaw({ op: "handoff", sessionId: sourceSessionId, requestId })) {
        setHandoffPending(true);
      } else {
        closeHandoffWindow();
      }
    }
  }, [closeHandoffWindow, sendRaw]);
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
    const requestId = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
    const request: CwdHarnessRequest = { requestId, cwd, connectionEpoch };
    latestCwdRequestRef.current = request;
    setHarnessSnapshot((current) => harnessSnapshotForCwdCheck(current, cwd));
    sendRaw({ op: "check-cwd", ...request });
  }, [connectionEpoch, sendRaw]);
  const clearError = useCallback(() => setLastError(""), []);

  return {
    ready,
    connectionEpoch,
    providers,
    harnessSnapshot,
    harnessCatalogs,
    capabilities,
    defaultCwd,
    ctrlJ,
    phase,
    session,
    routing,
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
    handoffPending,
    start,
    compose,
    reply,
    stop,
    focusTerminal,
    setOption,
    fork,
    handoff,
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

export function latestRouting(events: AgentEvent[]): Extract<AgentEvent, { kind: "routing" }> | null {
  for (let i = events.length - 1; i >= 0; i--) {
    if (events[i].kind === "routing") return events[i] as Extract<AgentEvent, { kind: "routing" }>;
  }
  return null;
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
