import type {
  Adapter,
  AgentEvent,
  CommandEntry,
  CommandTrigger,
  ChangedFile,
  OptionValue,
  ProviderCapabilities,
  ProviderDef,
  SessionCtx,
  SessionOption,
  SessionStatus,
} from "./types";
import { claudeAdapter } from "./adapters/claude";
import { codexAdapter } from "./adapters/codex";
import { piAdapter } from "./adapters/pi";
import { makeAcpAdapter } from "./adapters/acp";
import { resolveGhosttyTheme, resolveGhosttyThemeAsync, type GhosttyTheme } from "./theme";
import { existsSync, readFileSync, statSync, watch, type FSWatcher } from "node:fs";
import { readdir, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { basename as pathBasename, extname, isAbsolute, join, relative, resolve } from "node:path";

const PORT = Number(process.env.CMUX_AGENT_UI_PORT ?? 7739);

// The sidecar binds loopback only, but browsers can still reach loopback from
// arbitrary web origins (CSRF against the WS control plane) and DNS rebinding
// can defeat a bind-address check alone. Require a loopback Host header and,
// for browser-originated requests, a same-origin Origin header. Requests
// without an Origin header (CLI curl, Bun's WebSocket client) are trusted.
const ALLOWED_HOSTS = new Set([`127.0.0.1:${PORT}`, `localhost:${PORT}`, `[::1]:${PORT}`]);

function hasTrustedHost(req: Request): boolean {
  return ALLOWED_HOSTS.has(req.headers.get("host") ?? "");
}

function hasTrustedOrigin(req: Request): boolean {
  const origin = req.headers.get("origin");
  if (origin === null) return true;
  try {
    const u = new URL(origin);
    return u.protocol === "http:" && ALLOWED_HOSTS.has(u.host);
  } catch {
    return false;
  }
}

// Under launchd the PATH is minimal; make sure the agent CLIs resolve.
{
  const home = process.env.HOME ?? "";
  const extra = [`${home}/.local/bin`, `${home}/.bun/bin`, "/opt/homebrew/bin", "/usr/local/bin"];
  const cur = (process.env.PATH ?? "").split(":");
  process.env.PATH = [...extra.filter((p) => !cur.includes(p)), ...cur].join(":");
}
const ROOT = import.meta.dir;
const DEFAULT_CWD = `${ROOT}/scratch`;
const ICON_ROOT = resolve(ROOT, "../Assets.xcassets/AgentIcons");
const CATALOG_TTL_MS = 10 * 60_000;
const FILES_TTL_MS = 30_000;
const FILES_LIMIT = 5_000;
const FILE_DIFF_ALLOWLIST_LIMIT = 5_000;
const MAX_SESSION_EVENTS = 5_000;
const GIT_TIMEOUT_MS = 10_000;
const DONE_FILES_TIMEOUT_MS = 2_000;
const TURN_BASELINE_TIMEOUT_MS = 3_000;
const MAX_TURN_BASELINES = 4;
const GEMINI_MODELS = [
  { value: "gemini-3.1-pro-preview", label: "Gemini 3.1 Pro Preview" },
  { value: "gemini-3-pro-preview", label: "Gemini 3 Pro Preview" },
  { value: "gemini-3-flash-preview", label: "Gemini 3 Flash Preview" },
  { value: "gemini-2.5-pro", label: "Gemini 2.5 Pro" },
  { value: "gemini-2.5-flash", label: "Gemini 2.5 Flash" },
  { value: "gemini-2.5-flash-lite", label: "Gemini 2.5 Flash Lite" },
];

const PROVIDERS: ProviderDef[] = [
  { id: "claude", label: "Claude Code", adapter: "claude", cmd: ["claude"], installCommand: "npm i -g @anthropic-ai/claude-code" },
  { id: "codex", label: "Codex", adapter: "codex", cmd: ["codex"], installCommand: "npm i -g @openai/codex" },
  { id: "opencode", label: "OpenCode", adapter: "acp", cmd: ["opencode", "acp"], installCommand: "npm i -g opencode-ai" },
  { id: "pi", label: "pi", adapter: "pi", cmd: ["pi"], installCommand: "npm i -g @mariozechner/pi" },
  {
    id: "gemini",
    label: "Gemini",
    adapter: "acp",
    cmd: ["gemini", "--acp"],
    autoApproveArgs: ["--yolo"],
    installCommand: "npm i -g @google/gemini-cli",
    models: GEMINI_MODELS,
    defaultModel: "gemini-3.1-pro-preview",
  },
];

const adapters = new Map<string, Adapter>();
for (const def of PROVIDERS) {
  if (def.adapter === "claude") adapters.set(def.id, claudeAdapter);
  else if (def.adapter === "codex") adapters.set(def.id, codexAdapter);
  else if (def.adapter === "pi") adapters.set(def.id, piAdapter);
  else if (def.adapter === "acp") adapters.set(def.id, makeAcpAdapter(def));
}

interface Session extends SessionCtx {
  adapter: Adapter;
  sockets: Set<Bun.ServerWebSocket<WsData>>;
  createdAt: number;
}
interface WsData {
  subscribed: string | null;
}

const sessions = new Map<string, Session>();
const allSockets = new Set<Bun.ServerWebSocket<WsData>>();
let fileTheme = resolveGhosttyTheme();
let cmuxThemeOverride: GhosttyTheme | null = null;
let currentTheme = fileTheme;
const startRequests = new Map<string, { createdAt: number; promise: Promise<Session> }>();
type AttributionMode = "new-turn" | "current-turn";
type InternalDoneEvent = Extract<AgentEvent, { kind: "done" }> & { generation?: number };
const optionCatalog = new Map<string, {
  options: SessionOption[];
  fetchedAt: number;
  refreshing?: Promise<SessionOption[]>;
}>();
const commandCatalog = new Map<string, {
  groups: { trigger: CommandTrigger; commands: CommandEntry[] }[];
  fetchedAt: number;
  refreshing?: Promise<{ trigger: CommandTrigger; commands: CommandEntry[] }[]>;
}>();
const fileCatalog = new Map<string, { files: string[]; fetchedAt: number; refreshing?: Promise<string[]> }>();

// The cwd-keyed catalogs grow one entry per directory ever chatted in; in the
// long-lived launchd sidecar that is unbounded. Evict the stalest settled
// entries beyond a small cap (in-flight refreshes are skipped).
const MAX_CWD_CATALOG_ENTRIES = 64;
const START_REQUEST_TTL_MS = 60_000;
function pruneCwdCatalog(map: Map<string, { fetchedAt: number; refreshing?: Promise<unknown> }>) {
  while (map.size > MAX_CWD_CATALOG_ENTRIES) {
    let oldestKey: string | null = null;
    let oldestAt = Infinity;
    for (const [key, entry] of map) {
      if (entry.refreshing) continue;
      if (entry.fetchedAt < oldestAt) {
        oldestAt = entry.fetchedAt;
        oldestKey = key;
      }
    }
    if (oldestKey === null) return;
    map.delete(oldestKey);
  }
}

function pruneStartRequests() {
  const now = Date.now();
  for (const [key, entry] of startRequests) {
    if (now - entry.createdAt > START_REQUEST_TTL_MS) startRequests.delete(key);
  }
}
const keyConfig = await readKeyConfig();

function sessionSummary(s: Session) {
  return {
    id: s.id,
    provider: s.provider,
    cwd: s.cwd,
    title: s.title,
    status: s.status,
    createdAt: s.createdAt,
    capabilities: capabilitiesFor(s.provider),
  };
}

function capabilitiesFor(provider: string): ProviderCapabilities {
  return adapters.get(provider)?.capabilities ?? { options: [], triggers: [] };
}

function capabilitiesMap(): Record<string, ProviderCapabilities> {
  return Object.fromEntries(PROVIDERS.map((p) => [p.id, capabilitiesFor(p.id)]));
}

function providerInfo(p: ProviderDef) {
  return {
    id: p.id,
    label: p.label,
    // Bun.which ignores runtime process.env.PATH mutations (it reads the
    // process's original environ), so pass the prepended PATH explicitly or
    // every provider reads as uninstalled under launchd's minimal PATH.
    installed: Boolean(Bun.which(p.cmd?.[0] ?? p.id, { PATH: process.env.PATH })),
    installCommand: p.installCommand,
    ...(providerIconInfo.get(p.id) ?? {}),
  };
}

function broadcastSessions() {
  const payload = JSON.stringify({
    kind: "sessions",
    sessions: [...sessions.values()].sort((a, b) => b.createdAt - a.createdAt).map(sessionSummary),
  });
  for (const ws of allSockets) ws.send(payload);
}

function createSession(
  provider: string,
  cwd: string,
  autoApprove: boolean,
  title: string,
  startOptions: Record<string, OptionValue> = {},
): Session {
  const adapter = adapters.get(provider);
  if (!adapter) throw new Error(`unknown provider: ${provider}`);
  const id = crypto.randomUUID().slice(0, 8);
  const sess: Session = {
    id,
    provider,
    cwd,
    title,
    autoApprove,
    startOptions,
    seedOptions: optionCatalog.get(provider)?.options,
    status: "idle",
    events: [],
    internal: {},
    adapter,
    sockets: new Set(),
    createdAt: Date.now(),
    emit(evt: AgentEvent) {
      if (evt.kind === "done") {
        emitDoneAfterFiles(sess, evt);
        return;
      }
      emitSessionEvent(sess, evt);
    },
    setStatus(status: SessionStatus) {
      const pendingDone = sess.internal.pendingDoneEmit as Promise<void> | undefined;
      if (status === "idle" && pendingDone) {
        const pendingGeneration = Number(sess.internal.pendingDoneGeneration ?? sess.internal.turnGeneration ?? 0);
        pendingDone.finally(() => {
          if (Number(sess.internal.turnGeneration ?? 0) === pendingGeneration) sess.setStatus(status);
        });
        return;
      }
      if (sess.status === status) return;
      sess.status = status;
      const payload = JSON.stringify({ kind: "session-status", sessionId: id, status });
      for (const ws of sess.sockets) ws.send(payload);
      broadcastSessions();
    },
  };
  sessions.set(id, sess);
  broadcastSessions();
  return sess;
}

function emitSessionEvent(sess: Session, evt: AgentEvent) {
  const generation = currentAttributionGeneration(sess);
  const generations = eventGenerations(sess);
  recordSessionEventSideEffects(sess, evt);
  sess.events.push(evt);
  generations.push(generation);
  capSessionEvents(sess);
  broadcastSessionEvent(sess, evt);
}

function recordSessionEventSideEffects(sess: Session, evt: AgentEvent) {
  if (evt.kind === "files-changed") recordFileDiffAllowlist(sess, evt.files);
}

function eventGenerations(sess: Session): number[] {
  let generations = sess.internal.eventGenerations as number[] | undefined;
  if (!generations || generations.length !== sess.events.length) {
    generations = sess.events.map(() => 0);
    sess.internal.eventGenerations = generations;
  }
  return generations;
}

function capSessionEvents(sess: Session) {
  const generations = eventGenerations(sess);
  // Long agent streams accumulate thousands of retained events in this
  // long-lived process; cap the replayable transcript per session.
  if (sess.events.length > MAX_SESSION_EVENTS) {
    const drop = sess.events.length - MAX_SESSION_EVENTS;
    sess.events.splice(0, drop);
    generations.splice(0, drop);
    if (sess.events[0]?.kind !== "status" || !sess.events[0].text.startsWith("(transcript truncated")) {
      sess.events.unshift({ kind: "status", text: "(transcript truncated: older events dropped)" });
      generations.unshift(generations[0] ?? 0);
    }
  }
}

function broadcastSessionEvent(sess: Session, evt: AgentEvent) {
  const payload = JSON.stringify({ kind: "event", sessionId: sess.id, evt });
  for (const ws of sess.sockets) ws.send(payload);
}

function broadcastSessionHistory(sess: Session) {
  const payload = JSON.stringify({
    kind: "history",
    sessionId: sess.id,
    session: sessionSummary(sess),
    events: sess.events,
  });
  for (const ws of sess.sockets) ws.send(payload);
}

function activeAttributionGenerations(sess: Session): number[] {
  let generations = sess.internal.activeTurnGenerations as number[] | undefined;
  if (!generations) {
    generations = [];
    sess.internal.activeTurnGenerations = generations;
  }
  return generations;
}

function syncActiveAttributionGeneration(sess: Session) {
  const generation = activeAttributionGenerations(sess)[0];
  if (generation) sess.internal.activeTurnGeneration = generation;
  else delete sess.internal.activeTurnGeneration;
}

function activeAttributionGeneration(sess: Session): number | undefined {
  const generations = activeAttributionGenerations(sess);
  return generations[0] ?? (typeof sess.internal.activeTurnGeneration === "number" ? sess.internal.activeTurnGeneration : undefined);
}

function currentAttributionGeneration(sess: Session): number {
  return activeAttributionGeneration(sess) ?? 0;
}

function beginAttributionTurn(sess: Session, generation: number) {
  activeAttributionGenerations(sess).push(generation);
  syncActiveAttributionGeneration(sess);
}

function finishAttributionTurn(sess: Session, generation: number) {
  const generations = activeAttributionGenerations(sess);
  const index = generations.indexOf(generation);
  if (index >= 0) generations.splice(index, 1);
  syncActiveAttributionGeneration(sess);
}

function adapterAttributionMode(sess: Session): AttributionMode {
  const fn = (sess.adapter as Adapter & { attributionMode?: (sess: SessionCtx) => AttributionMode }).attributionMode;
  return fn?.(sess) ?? "new-turn";
}

function publicDoneEvent(evt: InternalDoneEvent): Extract<AgentEvent, { kind: "done" }> {
  const { generation: _generation, ...publicEvt } = evt;
  return publicEvt;
}

export function insertDeferredTurnEvents(events: AgentEvent[], generations: number[], generation: number, finalEvents: AgentEvent[]): { insertedAt: number; dropped: boolean } {
  if (!finalEvents.length) return { insertedAt: events.length, dropped: false };
  if (events.some((evt, index) => generations[index] === generation && evt.kind === "done")) {
    return { insertedAt: events.length, dropped: true };
  }
  let insertedAt = events.length;
  for (let i = 0; i < events.length; i++) {
    if (generations[i] > generation && events[i].kind === "user") {
      insertedAt = i;
      break;
    }
  }
  events.splice(insertedAt, 0, ...finalEvents);
  generations.splice(insertedAt, 0, ...finalEvents.map(() => generation));
  return { insertedAt, dropped: false };
}

function emitDoneAfterFiles(sess: Session, evt: InternalDoneEvent) {
  const generation = typeof evt.generation === "number" ? evt.generation : 0;
  const publicEvt = publicDoneEvent(evt);
  if (!generation) {
    emitSessionEvent(sess, publicEvt);
    return;
  }
  const previousAttribution = sess.internal.filesAttributionRunning as Promise<void> | undefined;
  const pending = (async () => {
    if (previousAttribution) await previousAttribution.catch(() => {});
    const finalEvents: AgentEvent[] = [];
    const fileEvents = await filesChangedEvents(sess, generation, DONE_FILES_TIMEOUT_MS).catch((err) => {
      console.error("[agent-chat] files-changed failed", err);
      return [] as AgentEvent[];
    });
    finalEvents.push(...fileEvents);
    finalEvents.push(publicEvt);
    const oldLength = sess.events.length;
    const result = insertDeferredTurnEvents(sess.events, eventGenerations(sess), generation, finalEvents);
    if (result.dropped) return;
    for (const finalEvt of finalEvents) recordSessionEventSideEffects(sess, finalEvt);
    capSessionEvents(sess);
    if (result.insertedAt >= oldLength) {
      for (const finalEvt of finalEvents) broadcastSessionEvent(sess, finalEvt);
    } else {
      broadcastSessionHistory(sess);
    }
  })();
  sess.internal.pendingDoneEmit = pending;
  sess.internal.pendingDoneGeneration = generation;
  sess.internal.filesAttributionRunning = pending;
  pending.finally(() => {
    finishAttributionTurn(sess, generation);
    if (sess.internal.pendingDoneEmit === pending) delete sess.internal.pendingDoneEmit;
    if (sess.internal.pendingDoneGeneration === generation) delete sess.internal.pendingDoneGeneration;
    if (sess.internal.filesAttributionRunning === pending) delete sess.internal.filesAttributionRunning;
  });
}

function sendPrompt(sess: Session, prompt: string) {
  const activeGeneration = activeAttributionGeneration(sess);
  if (adapterAttributionMode(sess) === "current-turn" && activeGeneration) {
    sess.emit({ kind: "user", text: prompt });
    Promise.resolve((sess.adapter.send as any)(sess, prompt, activeGeneration)).catch((err) => {
      console.error("[agent-chat] send failed", err);
      sess.emit({ kind: "error", message: safeErrorMessage("send", err) });
      sess.emit({ kind: "done", generation: activeGeneration } as any);
      sess.setStatus("idle");
    });
    return;
  }
  const generation = Number(sess.internal.turnGeneration ?? 0) + 1;
  sess.internal.turnGeneration = generation;
  beginAttributionTurn(sess, generation);
  const baselines = turnBaselines(sess);
  const baseline = captureDirtyBaseline(sess.cwd, TURN_BASELINE_TIMEOUT_MS).catch((err) => ({
    files: new Map<string, DirtyPathState>(),
    failed: String(err instanceof Error ? err.message : err),
  }));
  baselines.set(generation, baseline);
  pruneTurnBaselines(baselines);
  sess.emit({ kind: "user", text: prompt });
  // Conscious tradeoff: the prompt dispatches IMMEDIATELY and the baseline
  // captures concurrently. Gating send on capture cost up to ~3.5s per
  // message in large dirty repos (the primary chat path); the price of not
  // gating is that files the agent edits within the capture window may be
  // absorbed into the baseline and omitted from the cosmetic files-changed
  // block. Turn completion still awaits the stored baseline promise.
  Promise.resolve((sess.adapter.send as any)(sess, prompt, generation)).catch((err) => {
    console.error("[agent-chat] send failed", err);
    sess.emit({ kind: "error", message: safeErrorMessage("send", err) });
    // The UI treats "done" as the turn boundary; without it a failed send
    // leaves an open streaming block with no footer.
    sess.emit({ kind: "done", generation } as any);
    sess.setStatus("idle");
  });
}

function refreshSession(sess: Session) {
  Promise.resolve(sess.adapter.refreshOptions?.(sess)).catch((err) => {
    console.error("[agent-chat] refresh-options failed", err);
    sess.emit({ kind: "error", message: safeErrorMessage("list-options", err) });
  });
}

async function forkSession(source: Session): Promise<Session> {
  if (!source.adapter.forkSession) throw new Error(`${source.provider} does not support fork`);
  await assertCwd(source.cwd);
  const fork = createSession(source.provider, source.cwd, source.autoApprove, source.title, { ...source.startOptions });
  fork.events = source.events.slice();
  rebuildFileDiffAllowlist(fork);
  try {
    await source.adapter.forkSession(source, fork);
    refreshSession(fork);
    return fork;
  } catch (err) {
    fork.adapter.dispose(fork);
    sessions.delete(fork.id);
    broadcastSessions();
    throw err;
  }
}

async function checkCwd(cwd: string): Promise<{ ok: boolean; message?: string }> {
  try {
    const s = await stat(cwd);
    if (s.isDirectory()) return { ok: true };
  } catch {
    // Fall through to the stable user-facing message.
  }
  return { ok: false, message: `working directory does not exist: ${cwd}` };
}

async function assertCwd(cwd: string) {
  const res = await checkCwd(cwd);
  if (!res.ok) throw new Error(res.message);
}

function parseOptions(raw: unknown): Record<string, OptionValue> {
  if (!raw || typeof raw !== "object") return {};
  const out: Record<string, OptionValue> = {};
  for (const [k, v] of Object.entries(raw as Record<string, unknown>)) {
    if (typeof v === "string" || typeof v === "boolean") out[k] = v;
  }
  return out;
}

function applyAutoApproveDefaults(provider: string, autoApprove: boolean, raw: Record<string, OptionValue>): Record<string, OptionValue> {
  const out = { ...raw };
  if (provider === "claude") {
    if (out.permissionMode === undefined) out.permissionMode = autoApprove ? "acceptEdits" : "default";
  } else if (provider === "codex") {
    if (out.approvals === undefined) out.approvals = autoApprove ? "never" : "on-request";
    if (out.sandbox === undefined) out.sandbox = autoApprove ? "workspace-write" : "read-only";
  } else if (provider === "opencode" || provider === "gemini") {
    if (out.autoApprove === undefined) out.autoApprove = autoApprove;
  }
  return out;
}

async function sanitizeStartOptions(provider: string, cwd: string, raw: Record<string, OptionValue>): Promise<Record<string, OptionValue>> {
  if (!Object.keys(raw).length) return raw;
  const catalog = await catalogOptions(provider, cwd, { refreshMissing: false });
  return filterOptions(raw, catalog);
}

function filterOptions(raw: Record<string, OptionValue>, catalog: SessionOption[]): Record<string, OptionValue> {
  const byId = new Map(catalog.map((o) => [o.id, o]));
  const out: Record<string, OptionValue> = {};
  for (const [id, value] of Object.entries(raw)) {
    const option = byId.get(id);
    if (!option) continue;
    if (option.kind === "toggle" && typeof value === "boolean") out[id] = value;
    if (option.kind === "select" && typeof value === "string" && option.choices?.some((c) => c.value === value && !c.disabled)) out[id] = value;
  }
  return out;
}

function fallbackOptions(provider: string): SessionOption[] {
  return adapters.get(provider)?.capabilities?.options ?? [];
}

function shouldRefreshCatalog(provider: string): boolean {
  const entry = optionCatalog.get(provider);
  return !entry || Date.now() - entry.fetchedAt > CATALOG_TTL_MS;
}

function refreshCatalog(provider: string, cwd: string): Promise<SessionOption[]> {
  const adapter = adapters.get(provider);
  if (!adapter) return Promise.reject(new Error(`unknown provider: ${provider}`));
  const current = optionCatalog.get(provider);
  if (current?.refreshing) return current.refreshing;
  const refreshing = Promise.resolve(adapter.listOptions?.(cwd) ?? adapter.capabilities?.options ?? [])
    .then((options) => {
      optionCatalog.set(provider, { options, fetchedAt: Date.now() });
      return options;
    })
    .catch((err) => {
      if (!optionCatalog.has(provider)) optionCatalog.set(provider, { options: fallbackOptions(provider), fetchedAt: Date.now() });
      throw err;
    })
    .finally(() => {
      const entry = optionCatalog.get(provider);
      if (entry?.refreshing === refreshing) optionCatalog.set(provider, { options: entry.options, fetchedAt: entry.fetchedAt });
    });
  optionCatalog.set(provider, { options: current?.options ?? fallbackOptions(provider), fetchedAt: current?.fetchedAt ?? 0, refreshing });
  return refreshing;
}

async function catalogOptions(provider: string, cwd: string, opts: { refreshMissing?: boolean } = {}): Promise<SessionOption[]> {
  if (!adapters.has(provider)) throw new Error(`unknown provider: ${provider}`);
  const entry = optionCatalog.get(provider);
  if (entry) {
    if (!entry.fetchedAt && entry.refreshing && opts.refreshMissing !== false) {
      try {
        return await entry.refreshing;
      } catch {
        return fallbackOptions(provider);
      }
    }
    if (shouldRefreshCatalog(provider)) refreshCatalog(provider, cwd).catch(() => {});
    return entry.options;
  }
  if (opts.refreshMissing === false) {
    refreshCatalog(provider, cwd).catch(() => {});
    return fallbackOptions(provider);
  }
  try {
    return await refreshCatalog(provider, cwd);
  } catch {
    return fallbackOptions(provider);
  }
}

async function cachedCommands(provider: string, cwd: string): Promise<{ trigger: CommandTrigger; commands: CommandEntry[] }[]> {
  const adapter = adapters.get(provider);
  if (!adapter) throw new Error(`unknown provider: ${provider}`);
  const key = `${provider}:${resolve(cwd || DEFAULT_CWD)}`;
  const entry = commandCatalog.get(key);
  if (entry) {
    if (!entry.fetchedAt && entry.refreshing) return entry.refreshing;
    if (Date.now() - entry.fetchedAt <= CATALOG_TTL_MS) return entry.groups;
    if (entry.refreshing) return entry.groups;
  }
  const refreshing = Promise.resolve(adapter.listCommands?.(cwd) ?? [])
    .then((groups) => {
      commandCatalog.set(key, { groups, fetchedAt: Date.now() });
      pruneCwdCatalog(commandCatalog);
      return groups;
    })
    .catch((err) => {
      if (!commandCatalog.has(key)) commandCatalog.set(key, { groups: [], fetchedAt: Date.now() });
      throw err;
    })
    .finally(() => {
      const current = commandCatalog.get(key);
      if (current?.refreshing === refreshing) commandCatalog.set(key, { groups: current.groups, fetchedAt: current.fetchedAt });
    });
  commandCatalog.set(key, { groups: entry?.groups ?? [], fetchedAt: entry?.fetchedAt ?? 0, refreshing });
  return refreshing;
}

async function readKeyConfig(): Promise<{ ctrlJ: "newline" | "menu" }> {
  try {
    const text = await Bun.file(resolve(homedir(), ".config/cmux/cmux.json")).text();
    const parsed = JSON.parse(text);
    const value = parsed?.agentChat?.keys?.ctrlJ;
    return { ctrlJ: value === "menu" ? "menu" : "newline" };
  } catch {
    return { ctrlJ: "newline" };
  }
}

interface UiConfig {
  fonts: {
    sansFamily?: string;
    baseSize?: number;
    monoFamily?: string;
    codeSize?: number;
    codeLineHeight?: number;
  };
}

let uiConfigCache: { value: UiConfig; at: number } | null = null;

function resolveUiConfig(): UiConfig {
  if (uiConfigCache && Date.now() - uiConfigCache.at < 3000) return uiConfigCache.value;
  const value = readUiConfig();
  uiConfigCache = { value, at: Date.now() };
  return value;
}

function readUiConfig(): UiConfig {
  try {
    const text = readFileSync(resolve(homedir(), ".config/cmux/cmux.json"), "utf8");
    const parsed = JSON.parse(text);
    const fonts = parsed?.agentChat?.fonts ?? {};
    const num = (value: unknown) => typeof value === "number" && Number.isFinite(value) && value > 0 ? value : undefined;
    const str = (value: unknown) => typeof value === "string" && value.trim() ? value.trim() : undefined;
    return {
      fonts: {
        sansFamily: str(fonts.sansFamily ?? fonts.bodyFamily ?? fonts.family),
        baseSize: num(fonts.baseSize ?? fonts.bodySize),
        monoFamily: str(fonts.monoFamily ?? fonts.codeFamily),
        codeSize: num(fonts.codeSize ?? fonts.monoSize),
        codeLineHeight: num(fonts.codeLineHeight),
      },
    };
  } catch {
    return { fonts: {} };
  }
}

async function cachedFiles(cwd: string): Promise<string[]> {
  const key = resolve(cwd || DEFAULT_CWD);
  const entry = fileCatalog.get(key);
  if (entry) {
    if (!entry.fetchedAt && entry.refreshing) return entry.refreshing;
    if (Date.now() - entry.fetchedAt <= FILES_TTL_MS) return entry.files;
    if (!entry.refreshing) {
      const refreshing = loadFiles(key)
        .then((files) => {
          fileCatalog.set(key, { files, fetchedAt: Date.now() });
          pruneCwdCatalog(fileCatalog);
          return files;
        })
        .catch((err) => {
          console.warn(`file catalog refresh failed for ${key}: ${String(err)}`);
          return entry.files;
        });
      fileCatalog.set(key, { ...entry, refreshing });
    }
    return entry.files;
  }
  const refreshing = loadFiles(key).then((files) => {
    fileCatalog.set(key, { files, fetchedAt: Date.now() });
    pruneCwdCatalog(fileCatalog);
    return files;
  });
  fileCatalog.set(key, { files: [], fetchedAt: 0, refreshing });
  return refreshing;
}

async function loadFiles(cwd: string): Promise<string[]> {
  try {
    return limitFiles(await gitFiles(cwd));
  } catch {
    return limitFiles(await walkFiles(cwd));
  }
}

function limitFiles(files: string[]): string[] {
  return [...new Set(files.filter(Boolean).map((f) => f.replaceAll("\\", "/")))]
    .filter((f) => !f.startsWith("../") && f !== "..")
    .sort((a, b) => a.localeCompare(b))
    .slice(0, FILES_LIMIT);
}

export async function gitFiles(cwd: string): Promise<string[]> {
  const out = await gitOutputWithCodesResult(cwd, ["ls-files", "--cached", "--others", "--exclude-standard"], 500_000);
  return gitFilesFromOutput(out);
}

export function gitFilesFromOutput(out: { text: string; truncated: boolean }): string[] {
  const lines = out.text.split(/\r?\n/);
  if (out.truncated) lines.pop();
  return lines;
}

async function gitOutput(cwd: string, args: string[], maxBytes = 120_000, timeoutMs = GIT_TIMEOUT_MS): Promise<string> {
  return gitOutputWithCodes(cwd, args, maxBytes, [0], timeoutMs);
}

async function drainStream(stream: ReadableStream<Uint8Array>) {
  const reader = stream.getReader();
  try {
    for (;;) {
      const { done } = await reader.read();
      if (done) return;
    }
  } catch {
    // Process termination can close the pipe under us.
  } finally {
    reader.releaseLock();
  }
}

async function readStreamCapped(stream: ReadableStream<Uint8Array>, maxBytes: number): Promise<{ text: string; truncated: boolean }> {
  const reader = stream.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  let truncated = false;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!value?.byteLength) continue;
      const remaining = Math.max(0, maxBytes - size);
      if (remaining > 0) {
        const chunk = value.byteLength > remaining ? value.subarray(0, remaining) : value;
        chunks.push(chunk);
        size += chunk.byteLength;
      }
      if (value.byteLength > remaining || remaining === 0) {
        truncated = true;
        await reader.cancel().catch(() => {});
        break;
      }
    }
  } finally {
    reader.releaseLock();
  }
  const out = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.byteLength;
  }
  const text = new TextDecoder().decode(out);
  return { text, truncated };
}

export async function gitOutputWithCodesResult(cwd: string, args: string[], maxBytes = 120_000, okCodes: number[] = [0], timeoutMs = GIT_TIMEOUT_MS): Promise<{ text: string; truncated: boolean }> {
  const proc = Bun.spawn(["git", "-C", cwd, ...args], {
    stdout: "pipe",
    stderr: "pipe",
    env: { ...process.env },
  });
  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    proc.kill();
  }, timeoutMs);
  const stderrDrain = drainStream(proc.stderr);
  let out: { text: string; truncated: boolean };
  try {
    out = await readStreamCapped(proc.stdout, maxBytes);
  } catch (err) {
    proc.kill();
    clearTimeout(timer);
    await proc.exited.catch(() => {});
    await stderrDrain;
    if (timedOut) throw new Error("git command timed out");
    throw err;
  }
  if (out.truncated) proc.kill();
  const code = await proc.exited;
  clearTimeout(timer);
  await stderrDrain;
  if (timedOut) throw new Error("git command timed out");
  if (!out.truncated && !okCodes.includes(code)) throw new Error("git command failed");
  return out;
}

export async function gitOutputWithCodes(cwd: string, args: string[], maxBytes = 120_000, okCodes: number[] = [0], timeoutMs = GIT_TIMEOUT_MS): Promise<string> {
  return (await gitOutputWithCodesResult(cwd, args, maxBytes, okCodes, timeoutMs)).text;
}

async function isGitRepo(cwd: string, timeoutMs = GIT_TIMEOUT_MS): Promise<boolean> {
  try {
    return (await gitOutput(cwd, ["rev-parse", "--is-inside-work-tree"], 1_000, timeoutMs)).trim() === "true";
  } catch {
    return false;
  }
}

function statusPath(line: string): { path: string; status: string } | null {
  if (line.length < 4) return null;
  const code = line.slice(0, 2);
  const raw = line.slice(3).replace(/^"|"$/g, "");
  const arrow = raw.lastIndexOf(" -> ");
  const path = (arrow >= 0 ? raw.slice(arrow + 4) : raw).trim();
  if (!path) return null;
  const status = code.includes("?") ? "added" : code.includes("D") ? "deleted" : code.includes("R") ? "renamed" : "modified";
  return { path, status };
}

async function changedFiles(cwd: string, timeoutMs = GIT_TIMEOUT_MS): Promise<ChangedFile[]> {
  const deadline = makeDeadline(timeoutMs);
  if (!(await isGitRepo(cwd, remainingTimeout(deadline)))) return [];
  checkDeadline(deadline);
  const status = await gitOutput(cwd, ["status", "--porcelain=v1"], 80_000, remainingTimeout(deadline)).catch(() => "");
  checkDeadline(deadline);
  const numstat = await gitOutput(cwd, ["diff", "--numstat", "HEAD", "--"], 120_000, remainingTimeout(deadline)).catch(() => "");
  const stats = new Map<string, { adds: number; dels: number }>();
  for (const line of numstat.split(/\r?\n/)) {
    const [adds, dels, ...rest] = line.split("\t");
    const path = rest.join("\t").trim();
    if (!path) continue;
    stats.set(path, { adds: Number(adds) || 0, dels: Number(dels) || 0 });
  }
  const files: ChangedFile[] = [];
  for (const line of status.split(/\r?\n/)) {
    const parsed = statusPath(line);
    if (!parsed) continue;
    const stat = stats.get(parsed.path) ?? { adds: 0, dels: 0 };
    files.push({ path: parsed.path, adds: stat.adds, dels: stat.dels, status: parsed.status });
  }
  return files.sort((a, b) => a.path.localeCompare(b.path));
}

interface DirtyPathState {
  status: string;
  signature: string;
}

interface DirtyBaseline {
  files: Map<string, DirtyPathState>;
  failed?: string;
}

function makeDeadline(timeoutMs: number): number {
  return Date.now() + Math.max(0, timeoutMs);
}

function remainingTimeout(deadline: number): number {
  const remaining = deadline - Date.now();
  if (remaining <= 0) throw new Error("git operation timed out");
  return remaining;
}

function checkDeadline(deadline: number) {
  remainingTimeout(deadline);
}

function turnBaselines(sess: Session): Map<number, Promise<DirtyBaseline>> {
  let baselines = sess.internal.turnBaselines as Map<number, Promise<DirtyBaseline>> | undefined;
  if (!baselines) {
    baselines = new Map();
    sess.internal.turnBaselines = baselines;
  }
  return baselines;
}

function pruneTurnBaselines(baselines: Map<number, Promise<DirtyBaseline>>) {
  while (baselines.size > MAX_TURN_BASELINES) {
    const oldest = baselines.keys().next().value;
    if (oldest === undefined) return;
    baselines.delete(oldest);
  }
}

export function recordTurnBaselineForTest(sess: { internal: Record<string, unknown> }, generation: number) {
  const baselines = turnBaselines(sess as Session);
  baselines.set(generation, Promise.resolve({ files: new Map() }));
  pruneTurnBaselines(baselines);
}

async function captureDirtyBaseline(cwd: string, timeoutMs = GIT_TIMEOUT_MS): Promise<DirtyBaseline> {
  const deadline = makeDeadline(timeoutMs);
  return { files: await dirtyState(cwd, deadline) };
}

async function dirtyState(cwd: string, deadline = makeDeadline(GIT_TIMEOUT_MS)): Promise<Map<string, DirtyPathState>> {
  checkDeadline(deadline);
  if (!(await isGitRepo(cwd, remainingTimeout(deadline)))) return new Map();
  checkDeadline(deadline);
  const status = await gitOutput(cwd, ["status", "--porcelain=v1"], 200_000, remainingTimeout(deadline));
  const entries = status.split(/\r?\n/)
    .map(statusPath)
    .filter((entry): entry is { path: string; status: string } => Boolean(entry))
    .slice(0, FILES_LIMIT);
  const existing: string[] = [];
  const root = resolve(cwd);
  for (const entry of entries) {
    checkDeadline(deadline);
    const path = resolve(root, entry.path);
    const rel = relative(root, path);
    if (!rel || rel.startsWith("..") || isAbsolute(rel)) continue;
    const st = await stat(path).catch(() => null);
    if (st?.isFile()) existing.push(entry.path);
  }
  checkDeadline(deadline);
  const hashes = await hashDirtyPaths(cwd, existing, remainingTimeout(deadline));
  const state = new Map<string, DirtyPathState>();
  for (const entry of entries) {
    state.set(entry.path, {
      status: entry.status,
      signature: hashes.get(entry.path) ?? "missing",
    });
  }
  return state;
}

async function hashDirtyPaths(cwd: string, paths: string[], timeoutMs = GIT_TIMEOUT_MS): Promise<Map<string, string>> {
  if (!paths.length) return new Map();
  const proc = Bun.spawn(["git", "-C", cwd, "hash-object", "--stdin-paths"], {
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
    env: { ...process.env },
  });
  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    proc.kill();
  }, timeoutMs);
  const stderrDrain = drainStream(proc.stderr);
  proc.stdin.write(paths.join("\n") + "\n");
  proc.stdin.end();
  const out = await readStreamCapped(proc.stdout, Math.max(120_000, paths.length * 80)).finally(() => clearTimeout(timer));
  const code = await proc.exited;
  await stderrDrain;
  if (timedOut) throw new Error("git hash-object timed out");
  if (code !== 0 && !out.truncated) throw new Error("git hash-object failed");
  const hashes = out.text.split(/\r?\n/).filter(Boolean);
  const result = new Map<string, string>();
  for (let i = 0; i < paths.length && i < hashes.length; i++) result.set(paths[i], hashes[i]);
  return result;
}

export function filterChangedFilesSinceBaseline(files: ChangedFile[], baseline: Map<string, DirtyPathState>, endState: Map<string, DirtyPathState>): ChangedFile[] {
  return files.filter((file) => {
    const before = baseline.get(file.path);
    const after = endState.get(file.path);
    if (!after) return false;
    return !before || before.status !== after.status || before.signature !== after.signature;
  });
}

async function filesChangedEvents(sess: Session, generation: number, timeoutMs = GIT_TIMEOUT_MS): Promise<AgentEvent[]> {
  const baselines = turnBaselines(sess);
  const deadline = makeDeadline(timeoutMs);
  try {
    const files = await changedFiles(sess.cwd, remainingTimeout(deadline));
    if (!files.length) return [];
    const baseline = await (baselines.get(generation) ?? Promise.resolve({
      files: new Map<string, DirtyPathState>(),
      failed: "missing turn baseline",
    }));
    let filtered = files;
    const events: AgentEvent[] = [];
    if (baseline.failed) {
      events.push({ kind: "status", text: `files changed baseline unavailable; showing all dirty files (${baseline.failed})` });
    } else {
      try {
        filtered = filterChangedFilesSinceBaseline(files, baseline.files, await dirtyState(sess.cwd, deadline));
      } catch (err) {
        events.push({ kind: "status", text: `files changed baseline unavailable; showing all dirty files (${String(err instanceof Error ? err.message : err)})` });
      }
    }
    if (!filtered.length) return events;
    // No cross-turn dedupe: the baseline filter already limits the block to
    // files that changed during THIS turn, so an identical-looking list from
    // a later turn is a real, distinct edit that must be reported.
    // Diffs are intentionally fetched from the current working tree on click;
    // the files-changed block is turn-attributed, while diff content is best
    // effort current-tree state.
    events.push({ kind: "files-changed", files: filtered });
    return events;
  } finally {
    baselines.delete(generation);
  }
}

export function turnBaselineCountForTest(sess: { internal: Record<string, unknown> }): number {
  return (sess.internal.turnBaselines as Map<number, unknown> | undefined)?.size ?? 0;
}

export function turnBaselineKeysForTest(sess: { internal: Record<string, unknown> }): number[] {
  return [...((sess.internal.turnBaselines as Map<number, unknown> | undefined)?.keys() ?? [])];
}

export async function filesChangedEventsForTest(sess: Pick<Session, "cwd" | "internal">, generation: number, timeoutMs = GIT_TIMEOUT_MS): Promise<AgentEvent[]> {
  return filesChangedEvents(sess as Session, generation, timeoutMs);
}

export async function dirtyStateForTest(cwd: string, timeoutMs = GIT_TIMEOUT_MS): Promise<Map<string, DirtyPathState>> {
  return dirtyState(cwd, makeDeadline(timeoutMs));
}

export function emitSessionEventForTest(sess: Session, evt: AgentEvent) {
  emitSessionEvent(sess, evt);
}

export function emitDoneAfterFilesForTest(sess: Session, evt: Extract<AgentEvent, { kind: "done" }>) {
  emitDoneAfterFiles(sess, evt);
}

export function sendPromptForTest(sess: Session, prompt: string) {
  sendPrompt(sess, prompt);
}

async function emitFilesChanged(sess: Session, timeoutMs = GIT_TIMEOUT_MS) {
  const generation = Number(sess.internal.turnGeneration ?? 0);
  for (const evt of await filesChangedEvents(sess, generation, timeoutMs)) sess.emit(evt);
}

export function resolveFileDiffPath(cwd: string, path: string): string {
  if (path.includes("\0") || path.startsWith("../") || path === "..") throw new Error("invalid path");
  const root = resolve(cwd);
  const target = resolve(root, path);
  const rel = relative(root, target);
  if (!rel || rel.startsWith("..") || isAbsolute(rel)) throw new Error("invalid path");
  return rel.replaceAll("\\", "/");
}

function fileDiffAllowlist(sess: Session): Set<string> {
  let allowed = sess.internal.fileDiffAllowlist as Set<string> | undefined;
  if (!allowed) {
    allowed = new Set();
    sess.internal.fileDiffAllowlist = allowed;
  }
  return allowed;
}

function recordFileDiffAllowlist(sess: Session, files: ChangedFile[]) {
  const allowed = fileDiffAllowlist(sess);
  for (const file of files) {
    let safePath: string;
    try {
      safePath = resolveFileDiffPath(sess.cwd, file.path);
    } catch {
      continue;
    }
    if (allowed.has(safePath)) continue;
    while (allowed.size >= FILE_DIFF_ALLOWLIST_LIMIT) {
      const oldest = allowed.values().next().value;
      if (oldest === undefined) break;
      allowed.delete(oldest);
    }
    allowed.add(safePath);
  }
}

function rebuildFileDiffAllowlist(sess: Session) {
  delete sess.internal.fileDiffAllowlist;
  for (const evt of sess.events) {
    if (evt.kind === "files-changed") recordFileDiffAllowlist(sess, evt.files);
  }
}

function assertFileDiffAllowed(sess: Session, safePath: string) {
  if (!fileDiffAllowlist(sess).has(safePath)) throw new Error("path was not reported by this session");
}

export function recordFilesChangedForTest(sess: Pick<Session, "cwd" | "internal">, files: ChangedFile[]) {
  recordFileDiffAllowlist(sess as Session, files);
}

export function rebuildFileDiffAllowlistForTest(sess: Pick<Session, "cwd" | "events" | "internal">) {
  rebuildFileDiffAllowlist(sess as Session);
}

export function fileDiffAllowedForTest(sess: Pick<Session, "internal">, path: string): boolean {
  return Boolean((sess.internal.fileDiffAllowlist as Set<string> | undefined)?.has(path));
}

async function fileDiff(cwd: string, path: string): Promise<string> {
  if (!(await isGitRepo(cwd))) throw new Error("not a git repository");
  const safePath = resolveFileDiffPath(cwd, path);
  const tracked = await gitOutput(cwd, ["ls-files", "--error-unmatch", "--", safePath], 10_000)
    .then(() => true)
    .catch(() => false);
  const diff = tracked
    ? await gitOutputWithCodesResult(cwd, ["diff", "--no-ext-diff", "HEAD", "--", safePath], 80_000).catch(() => ({ text: "", truncated: false }))
    : await gitOutputWithCodesResult(cwd, ["diff", "--no-ext-diff", "--no-index", "--", "/dev/null", safePath], 80_000, [0, 1])
      .catch(() => ({ text: `diff unavailable for ${safePath}\n`, truncated: false }));
  let text = diff.text;
  if (diff.truncated) text += "\n[truncated]\n";
  if (!text.trim()) return `empty diff for ${safePath}\n`;
  return text.split(/\r?\n/).slice(0, 400).join("\n");
}

async function walkFiles(root: string): Promise<string[]> {
  const out: string[] = [];
  const skip = new Set([".git", "node_modules", ".hg", ".svn", ".cache", ".next", "dist", "build"]);
  async function visit(dir: string, depth: number) {
    if (out.length >= FILES_LIMIT || depth > 5) return;
    let entries: any[];
    try {
      entries = await readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const ent of entries) {
      if (out.length >= FILES_LIMIT) return;
      if (ent.name.startsWith(".") || skip.has(ent.name)) continue;
      const full = join(dir, ent.name);
      const rel = relative(root, full).replaceAll("\\", "/");
      if (ent.isDirectory()) {
        await visit(full, depth + 1);
      } else if (ent.isFile()) {
        out.push(rel);
      } else if (ent.isSymbolicLink()) {
        try {
          if ((await stat(full)).isFile()) out.push(rel);
        } catch {
          // Ignore broken links.
        }
      }
    }
  }
  await visit(root, 0);
  return out;
}

function iconFile(provider: string, dark: boolean): string | null {
  const file = provider === "claude" ? "Claude.imageset/Claude@2x.png"
    : provider === "codex" ? `Codex.imageset/${dark ? "Codex-dark@2x.png" : "Codex@2x.png"}`
      : provider === "opencode" ? "OpenCode.imageset/OpenCode@2x.png"
        : provider === "pi" ? "Pi.imageset/Pi.svg"
          : null;
  if (!file) return null;
  const resolved = resolve(ICON_ROOT, file);
  const rel = relative(ICON_ROOT, resolved);
  if (!rel || rel.startsWith("..") || isAbsolute(rel)) return null;
  return existsSync(resolved) ? resolved : null;
}

function iconResponse(url: URL): Response {
  const provider = url.pathname.slice("/icons/".length);
  if (!/^[a-z0-9_-]+$/i.test(provider)) return new Response("not found", { status: 404 });
  const file = iconFile(provider, url.searchParams.get("dark") === "1");
  if (!file) return new Response("not found", { status: 404 });
  const type = extname(file) === ".svg" ? "image/svg+xml" : "image/png";
  return new Response(Bun.file(file), {
    headers: {
      "content-type": type,
      "cache-control": "public, max-age=31536000, immutable",
    },
  });
}

const providerIconInfo = new Map(PROVIDERS.map((p) => {
  const iconUrl = iconFile(p.id, false) ? `/icons/${p.id}` : undefined;
  const iconDarkUrl = p.id === "codex" && iconFile(p.id, true) ? `/icons/${p.id}?dark=1` : undefined;
  return [p.id, { ...(iconUrl ? { iconUrl } : {}), ...(iconDarkUrl ? { iconDarkUrl } : {}) }];
}));

const ANSI_NAMES = [
  "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
  "bright-black", "bright-red", "bright-green", "bright-yellow", "bright-blue", "bright-magenta", "bright-cyan", "bright-white",
];
const DEFAULT_SANS = `-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif`;
const DEFAULT_MONO = `"Cascadia Code", "Cascadia Mono", "JetBrains Mono", "SF Mono", Menlo, ui-monospace, monospace`;

function quoteCssFontFamily(value: string): string | null {
  const clean = value
    .replace(/[\u0000-\u001f\u007f]/g, "")
    .replace(/[;{}<>]/g, "")
    .trim()
    .replace(/^["']|["']$/g, "")
    .trim();
  if (!clean) return null;
  return `"${clean.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}

export function cssFontFamily(value: string | undefined | null, fallback: string): string {
  if (!value) return fallback;
  const families = value.split(",").map(quoteCssFontFamily).filter(Boolean);
  return families.length ? `${families.join(", ")}, ${fallback}` : fallback;
}

function resolvedFontValues(theme: GhosttyTheme): Record<string, string> {
  const fonts = resolveUiConfig().fonts;
  const baseSize = fonts.baseSize ?? 14;
  const codeSize = fonts.codeSize ?? theme.fontSize ?? 12.5;
  const codeLineHeight = fonts.codeLineHeight ?? 1.5;
  const sans = cssFontFamily(fonts.sansFamily, DEFAULT_SANS);
  const mono = cssFontFamily(fonts.monoFamily ?? theme.fontFamily, DEFAULT_MONO);
  return {
    "--font-sans": sans,
    "--font-mono": mono,
    "--font-size-base": `${baseSize}px`,
    "--font-size-code": `${codeSize}px`,
    "--font-line-code": String(codeLineHeight),
  };
}

export function themeVarMap(theme: GhosttyTheme, opts: { transparent?: boolean; opacity?: number } = {}): Record<string, string> {
  const transparent = opts.transparent === true;
  const opacity = transparent ? (typeof opts.opacity === "number" && Number.isFinite(opts.opacity) ? opts.opacity : theme.opacity) : 1;
  const n = parseInt(theme.background.slice(1), 16);
  const rgb = `${(n >> 16) & 255}, ${(n >> 8) & 255}, ${n & 255}`;
  const vars: Record<string, string> = {
    "--bg": theme.background,
    "--fg": theme.foreground,
    "--bg-body": `rgba(${rgb}, ${opacity})`,
    "--bg-html": transparent ? "transparent" : theme.background,
    "--accent": theme.palette[12],
    "--green": theme.palette[2],
    "--red": theme.palette[1],
    "--amber": theme.palette[3],
    "--selection-background": theme.selectionBackground ?? theme.palette[4],
    "--cursor-color": theme.cursorColor ?? theme.foreground,
    ...resolvedFontValues(theme),
  };
  for (const [i, color] of theme.palette.entries()) {
    vars[`--ansi-${i}`] = color;
    vars[`--ansi-${ANSI_NAMES[i]}`] = color;
  }
  return vars;
}

function varsToCss(vars: Record<string, string>): string {
  return Object.entries(vars).map(([key, value]) => `${key}: ${value};`).join(" ");
}

export function themeCssVars(theme: GhosttyTheme, opts: { transparent?: boolean; opacity?: number } = {}): string {
  return varsToCss(themeVarMap(theme, opts));
}

function themeForClient(theme: GhosttyTheme): GhosttyTheme {
  return theme;
}

const THEME_POST_KEYS = [
  "background",
  "foreground",
  "palette",
  "selectionBackground",
  "cursorColor",
  "fontFamily",
  "fontSize",
  "opacity",
  "blur",
  "isLight",
  "source",
] as const;

function isColor(value: unknown): value is string {
  return typeof value === "string" && /^#[0-9a-fA-F]{6}$/.test(value);
}

function nullableColor(value: unknown): string | null {
  if (value === null) return null;
  if (isColor(value)) return value.toLowerCase();
  throw new Error("invalid theme color");
}

function requiredColor(value: unknown): string {
  if (isColor(value)) return value.toLowerCase();
  throw new Error("invalid theme color");
}

export function validateCmuxThemePayload(body: unknown): GhosttyTheme {
  if (!body || typeof body !== "object" || Array.isArray(body)) throw new Error("theme payload must be an object");
  const obj = body as Record<string, unknown>;
  // JSON encoders commonly omit null fields entirely (Swift's synthesized
  // Codable does), so absent nullable keys are treated as null; unexpected
  // keys are still rejected.
  for (const key of ["selectionBackground", "cursorColor", "fontFamily", "fontSize"]) {
    if (!(key in obj)) obj[key] = null;
  }
  const keys = Object.keys(obj).sort();
  const expected = [...THEME_POST_KEYS].sort();
  if (keys.length !== expected.length || keys.some((key, i) => key !== expected[i])) throw new Error("theme payload has unexpected keys");
  if (obj.source !== "cmux") throw new Error("theme source must be cmux");
  if (!Array.isArray(obj.palette) || obj.palette.length !== 16 || !obj.palette.every(isColor)) throw new Error("theme palette must contain 16 colors");
  const fontSize = obj.fontSize;
  if (fontSize !== null && (typeof fontSize !== "number" || !Number.isFinite(fontSize) || fontSize <= 0)) throw new Error("theme fontSize must be positive or null");
  const opacity = obj.opacity;
  const blur = obj.blur;
  if (typeof opacity !== "number" || !Number.isFinite(opacity) || opacity <= 0 || opacity > 1) throw new Error("theme opacity must be 0-1");
  if (typeof blur !== "number" || !Number.isFinite(blur) || blur < 0) throw new Error("theme blur must be non-negative");
  if (typeof obj.isLight !== "boolean") throw new Error("theme isLight must be boolean");
  if (obj.fontFamily !== null && typeof obj.fontFamily !== "string") throw new Error("theme fontFamily must be string or null");
  return {
    background: requiredColor(obj.background),
    foreground: requiredColor(obj.foreground),
    palette: obj.palette.map((color) => String(color).toLowerCase()),
    selectionBackground: nullableColor(obj.selectionBackground),
    cursorColor: nullableColor(obj.cursorColor),
    fontFamily: obj.fontFamily ? String(obj.fontFamily) : null,
    fontSize: fontSize === null ? null : Number(fontSize),
    opacity,
    blur,
    isLight: Boolean(obj.isLight),
    source: "cmux",
    sources: [],
  };
}

function sameTheme(a: GhosttyTheme, b: GhosttyTheme): boolean {
  return JSON.stringify(themeForClient(a)) === JSON.stringify(themeForClient(b));
}

function broadcastTheme(theme: GhosttyTheme) {
  const payload = JSON.stringify({ kind: "theme", theme: themeForClient(theme), vars: themeVarMap(theme) });
  for (const ws of allSockets) ws.send(payload);
}

function setCurrentTheme(theme: GhosttyTheme, source: "cmux" | "ghostty") {
  if (source === "cmux") cmuxThemeOverride = theme;
  else cmuxThemeOverride = null;
  currentTheme = theme;
}

export function themeOverrideStateForTest(action: "cmux" | "ghostty", theme: GhosttyTheme): { current: GhosttyTheme; hasOverride: boolean } {
  if (action === "ghostty") fileTheme = theme;
  setCurrentTheme(theme, action);
  return { current: currentTheme, hasOverride: cmuxThemeOverride !== null };
}

let themeWatchers: FSWatcher[] = [];
let themeRefreshTimer: ReturnType<typeof setTimeout> | null = null;
let themePollTimer: ReturnType<typeof setInterval> | null = null;
let watchedThemeSources: string[] = [];
let watchedThemeMtimes = new Map<string, number>();

function closeThemeWatchers() {
  for (const watcher of themeWatchers) watcher.close();
  themeWatchers = [];
}

function sameSources(a: string[], b: string[]): boolean {
  return a.length === b.length && a.every((value, i) => value === b[i]);
}

export function themeSourceMtimes(paths: string[]): Map<string, number> {
  const mtimes = new Map<string, number>();
  for (const path of paths) {
    try {
      mtimes.set(path, statSync(path).mtimeMs);
    } catch {
      mtimes.set(path, 0);
    }
  }
  return mtimes;
}

export function themeMtimesChangedForTest(prev: Map<string, number>, next: Map<string, number>): boolean {
  if (prev.size !== next.size) return true;
  for (const [path, mtime] of next) {
    if (prev.get(path) !== mtime) return true;
  }
  return false;
}

function armThemeWatchers(theme: GhosttyTheme) {
  const sources = [...new Set(theme.sources)].sort();
  watchedThemeMtimes = themeSourceMtimes(sources);
  if (sameSources(watchedThemeSources, sources)) return;
  closeThemeWatchers();
  watchedThemeSources = sources;
  for (const file of sources) {
    try {
      themeWatchers.push(watch(file, { persistent: false }, () => scheduleThemeRefresh()));
    } catch {
      // Missing files are still covered by the poll fallback and re-armed
      // after the next successful resolve.
    }
  }
}

function scheduleThemeRefresh() {
  if (themeRefreshTimer) clearTimeout(themeRefreshTimer);
  themeRefreshTimer = setTimeout(() => {
    themeRefreshTimer = null;
    refreshThemeNow().catch((err) => console.warn(`theme refresh failed: ${String(err)}`));
  }, 120);
}

export async function refreshThemeNow(): Promise<boolean> {
  const nextFileTheme = await resolveGhosttyThemeAsync(true);
  const changed = !sameTheme(fileTheme, nextFileTheme);
  fileTheme = nextFileTheme;
  armThemeWatchers(nextFileTheme);
  if (changed) {
    setCurrentTheme(nextFileTheme, "ghostty");
    broadcastTheme(nextFileTheme);
  }
  return changed;
}

function startThemeWatcher() {
  armThemeWatchers(fileTheme);
  if (themePollTimer) clearInterval(themePollTimer);
  // The poll exists only for atomic replaces or missing files that fs.watch
  // cannot stay attached to. It stats watched files cheaply and resolves
  // Ghostty only when an mtime/source-set change is observed.
  themePollTimer = setInterval(() => {
    const next = themeSourceMtimes(watchedThemeSources);
    if (!themeMtimesChangedForTest(watchedThemeMtimes, next)) return;
    watchedThemeMtimes = next;
    refreshThemeNow().catch((err) => console.warn(`theme poll refresh failed: ${String(err)}`));
  }, 5000);
}

export function themeMessageForTest(theme: GhosttyTheme): string {
  return JSON.stringify({ kind: "theme", theme: themeForClient(theme), vars: themeVarMap(theme) });
}

// Inject the resolved Ghostty theme as CSS variables at serve time so the
// page paints with the terminal's colors on first frame. `?transparent=1` is
// appended by openers that created the browser surface with
// transparent_background, so only genuinely transparent surfaces get an alpha
// body; `?opacity=` is a dogfood override.
function renderPage(url: URL): string {
  if (!cmuxThemeOverride) {
    fileTheme = resolveGhosttyTheme();
    currentTheme = fileTheme;
  }
  const transparent = url.searchParams.get("transparent") === "1";
  const override = parseFloat(url.searchParams.get("opacity") ?? "");
  // In opaque mode html paints the same solid bg as body, so nothing behind
  // the webview (a terminal surface) can composite through the transparent
  // document root. In transparent mode html stays clear on purpose so
  // background-opacity/blur show through.
  const css = `:root { ${themeCssVars(currentTheme, { transparent, opacity: Number.isNaN(override) ? undefined : override })} }`;
  // Shell: theme vars first (so the first paint is the terminal bg), the
  // static stylesheet, a mount point, and the bundled React app (Base UI).
  const script = url.pathname === "/gallery" ? "/gallery.js" : "/app.js";
  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>cmux agent</title>
<link rel="stylesheet" href="/app.css">
<style>${css}</style>
</head><body>
<div id="root"></div>
<script type="module" src="${script}"></script>
</body></html>`;
}

interface StaticAsset {
  route: string;
  bytes: ArrayBuffer;
  gzip: ArrayBuffer;
  type: string;
}

// Bundle the frontend entries with Bun. Built once at startup and cached by
// default; rebuilt on request only when CMUX_AGENT_UI_DEV=1 (dev iteration).
let assetCache: Map<string, StaticAsset> | null = null;
let cssAssetCache: StaticAsset | null = null;
let assetBuildPromise: Promise<Map<string, StaticAsset>> | null = null;
let cssAssetPromise: Promise<StaticAsset> | null = null;
let bundleBuildCount = 0;
let cssReadCount = 0;

function arrayBufferOf(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
}

function makeAsset(route: string, bytes: ArrayBuffer, type: string): StaticAsset {
  return { route, bytes, gzip: arrayBufferOf(Bun.gzipSync(bytes)), type };
}

function formatBytes(n: number): string {
  if (n > 1024 * 1024) return `${(n / 1024 / 1024).toFixed(2)} MB`;
  if (n > 1024) return `${Math.round(n / 1024)} KB`;
  return `${n} B`;
}

function bundleSizeLine(assets: Map<string, StaticAsset>): string {
  const app = assets.get("/app.js");
  const gallery = assets.get("/gallery.js");
  const part = (name: string, asset?: StaticAsset) => asset
    ? `${name} ${formatBytes(asset.bytes.byteLength)} raw / ${formatBytes(asset.gzip.byteLength)} gzip`
    : `${name} missing`;
  return `bundle ready: ${part("app.js", app)}; ${part("gallery.js", gallery)}`;
}

export async function buildBundles(): Promise<Map<string, StaticAsset>> {
  if (assetCache && process.env.CMUX_AGENT_UI_DEV !== "1") return assetCache;
  if (assetBuildPromise && process.env.CMUX_AGENT_UI_DEV !== "1") return assetBuildPromise;
  assetBuildPromise = buildBundlesFresh().finally(() => {
    assetBuildPromise = null;
  });
  return assetBuildPromise;
}

async function buildBundlesFresh(): Promise<Map<string, StaticAsset>> {
  bundleBuildCount += 1;
  const out = await Bun.build({
    entrypoints: [`${ROOT}/src/main.tsx`, `${ROOT}/src/gallery-main.tsx`],
    target: "browser",
    minify: true,
    splitting: true,
    outdir: `/tmp/cmux-agent-ui-${process.pid}`,
    define: { "process.env.NODE_ENV": '"production"' },
  });
  if (!out.success) {
    const msg = out.logs.map((l) => String(l)).join("\n");
    throw new Error("bundle failed:\n" + msg);
  }
  const assets = new Map<string, StaticAsset>();
  for (const output of out.outputs) {
    const base = pathBasename(output.path);
    const route = base === "main.js" ? "/app.js" : base === "gallery-main.js" ? "/gallery.js" : `/${base}`;
    const bytes = await output.arrayBuffer();
    assets.set(route, makeAsset(route, bytes, "application/javascript; charset=utf-8"));
  }
  assetCache = assets;
  console.log(bundleSizeLine(assets));
  return assets;
}

export async function cssAsset(): Promise<StaticAsset> {
  if (cssAssetCache && process.env.CMUX_AGENT_UI_DEV !== "1") return cssAssetCache;
  if (cssAssetPromise && process.env.CMUX_AGENT_UI_DEV !== "1") return cssAssetPromise;
  cssAssetPromise = cssAssetFresh().finally(() => {
    cssAssetPromise = null;
  });
  return cssAssetPromise;
}

async function cssAssetFresh(): Promise<StaticAsset> {
  cssReadCount += 1;
  const bytes = await Bun.file(`${ROOT}/public/app.css`).arrayBuffer();
  cssAssetCache = makeAsset("/app.css", bytes, "text/css; charset=utf-8");
  return cssAssetCache;
}

export function resetAssetCachesForTest() {
  assetCache = null;
  cssAssetCache = null;
  assetBuildPromise = null;
  cssAssetPromise = null;
  bundleBuildCount = 0;
  cssReadCount = 0;
}

export function assetCacheStatsForTest() {
  return { bundleBuildCount, cssReadCount };
}

function acceptsGzip(req: Request): boolean {
  return /\bgzip\b/.test(req.headers.get("accept-encoding") ?? "");
}

function assetResponse(req: Request, asset: StaticAsset): Response {
  if (acceptsGzip(req)) {
    return new Response(asset.gzip, {
      headers: {
        "content-type": asset.type,
        "content-encoding": "gzip",
        "vary": "Accept-Encoding",
        "cache-control": "no-cache",
      },
    });
  }
  return new Response(asset.bytes, {
    headers: {
      "content-type": asset.type,
      "vary": "Accept-Encoding",
      "cache-control": "no-cache",
    },
  });
}

function startServer() {
  const server = Bun.serve<WsData>({
    port: PORT,
    hostname: "127.0.0.1",
    async fetch(req, srv) {
    const url = new URL(req.url);
    if (!hasTrustedHost(req)) return new Response("forbidden", { status: 403 });
    if (url.pathname === "/ws") {
      if (!hasTrustedOrigin(req)) return new Response("forbidden", { status: 403 });
      return srv.upgrade(req, { data: { subscribed: null } })
        ? undefined
        : new Response("upgrade failed", { status: 400 });
    }
    if (url.pathname === "/healthz") return new Response("ok");
    if (url.pathname.startsWith("/icons/")) return iconResponse(url);
    if (url.pathname === "/app.js" || url.pathname === "/gallery.js" || /^\/chunk-[\w-]+\.js$/.test(url.pathname)) {
      try {
        const asset = (await buildBundles()).get(url.pathname);
        if (!asset) return new Response("not found", { status: 404 });
        return assetResponse(req, asset);
      } catch (err) {
        return new Response(`console.error(${JSON.stringify(String(err))})`, {
          status: 500,
          headers: { "content-type": "application/javascript; charset=utf-8" },
        });
      }
    }
    if (url.pathname === "/app.css") {
      return assetResponse(req, await cssAsset());
    }
    if (url.pathname === "/api/theme" && req.method === "POST") {
      if (!hasTrustedOrigin(req)) return Response.json({ error: "forbidden" }, { status: 403 });
      try {
        const theme = validateCmuxThemePayload(await req.json());
        setCurrentTheme(theme, "cmux");
        broadcastTheme(theme);
        return Response.json(themeForClient(theme));
      } catch (err) {
        return Response.json({ error: err instanceof Error ? err.message : String(err) }, { status: 400 });
      }
    }
    if (url.pathname === "/api/theme") {
      if (!cmuxThemeOverride) {
        fileTheme = resolveGhosttyTheme();
        currentTheme = fileTheme;
        armThemeWatchers(fileTheme);
      }
      return Response.json(themeForClient(currentTheme));
    }
    // REST for the CLI: create a session (optionally with a first prompt) and
    // get back its id/url; list sessions.
    if (url.pathname === "/api/sessions" && req.method === "POST") {
      if (!hasTrustedOrigin(req)) return Response.json({ error: "forbidden" }, { status: 403 });
      const body = await req.json().catch(() => ({}));
      const provider = String(body.provider ?? "claude");
      const prompt = String(body.prompt ?? "").trim();
      const cwd = String(body.cwd || DEFAULT_CWD);
      const title = prompt ? (prompt.length > 64 ? prompt.slice(0, 64) + "…" : prompt) : `${provider} chat`;
      let sess: Session;
      try {
        await assertCwd(cwd);
        const autoApprove = body.autoApprove !== false;
        const options = applyAutoApproveDefaults(provider, autoApprove, parseOptions(body.options));
        sess = createSession(provider, cwd, autoApprove, title, await sanitizeStartOptions(provider, cwd, options));
      } catch (err) {
        return Response.json({ error: String(err) }, { status: 400 });
      }
      refreshSession(sess);
      if (prompt) sendPrompt(sess, prompt);
      return Response.json({ id: sess.id, url: `http://127.0.0.1:${PORT}/s/${sess.id}` });
    }
    if (url.pathname === "/api/sessions" && req.method === "GET") {
      return Response.json([...sessions.values()].sort((a, b) => b.createdAt - a.createdAt).map(sessionSummary));
    }
    return new Response(renderPage(url), { headers: { "content-type": "text/html; charset=utf-8" } });
    },
    websocket: {
      open(ws) {
      allSockets.add(ws);
      ws.send(JSON.stringify({
        kind: "hello",
        providers: PROVIDERS.map(providerInfo),
        capabilities: capabilitiesMap(),
        defaultCwd: process.env.CMUX_AGENT_UI_CWD ?? DEFAULT_CWD,
        keys: keyConfig,
      }));
      ws.send(JSON.stringify({
        kind: "sessions",
        sessions: [...sessions.values()].sort((a, b) => b.createdAt - a.createdAt).map(sessionSummary),
      }));
      },
      close(ws) {
      allSockets.delete(ws);
      const sid = ws.data.subscribed;
      if (sid) sessions.get(sid)?.sockets.delete(ws);
      },
      message(ws, raw) {
      let msg: any;
      try {
        msg = JSON.parse(String(raw));
      } catch {
        return;
      }
      try {
        handleMessage(ws, msg);
      } catch (err) {
        sendWsError(ws, String(msg.op ?? ""), err);
      }
      },
    },
  });

  // Warm the bundle so the first page load doesn't pay the build cost, and so
  // a build error surfaces at startup rather than as a blank page.
  buildBundles().then(
    () => {},
    (err) => console.error(String(err)),
  );

  for (const p of PROVIDERS) {
    refreshCatalog(p.id, process.env.CMUX_AGENT_UI_CWD ?? DEFAULT_CWD).catch((err) => {
      console.warn(`catalog warm failed for ${p.id}: ${String(err)}`);
    });
  }
  startThemeWatcher();

  console.log(`cmux-agent-ui listening on http://127.0.0.1:${server.port}`);
}

function sendWsError(ws: Bun.ServerWebSocket<WsData>, op: string, err: unknown) {
  sendWsErrorDetails(ws, op, err);
}

function safeReason(err: unknown): string {
  const text = String(err instanceof Error ? err.message : err).toLowerCase();
  if (text.includes("working directory") || text.includes("enoent")) return "working directory is unavailable";
  if (text.includes("unknown provider")) return "unknown provider";
  if (text.includes("no session")) return "no session is available";
  if (text.includes("invalid path")) return "invalid path";
  if (text.includes("not reported")) return "file was not reported by this session";
  if (text.includes("not a git")) return "not a git repository";
  if (text.includes("timed out") || text.includes("timeout")) return "request timed out";
  if (text.includes("permission") || text.includes("auth") || text.includes("forbidden")) return "permission or authentication failed";
  if (text.includes("support")) return "operation is not supported";
  return "unexpected error";
}

function safeErrorMessage(op: string, err: unknown, context: { provider?: string } = {}): string {
  const reason = safeReason(err);
  if (op === "start") return `Failed to start ${context.provider ?? "agent"}: ${reason}`;
  if (op === "fork") return `Failed to fork chat: ${reason}`;
  if (op === "get-file-diff") return `Failed to load diff: ${reason}`;
  if (op === "send") return `Failed to send message: ${reason}`;
  if (op === "set-option") return `Failed to update option: ${reason}`;
  return `Request failed: ${reason}`;
}

function sendWsErrorDetails(
  ws: Bun.ServerWebSocket<WsData>,
  op: string,
  err: unknown,
  details: { provider?: string; requestId?: string; sessionId?: string; path?: string } = {},
) {
  console.error(`[agent-chat] ${op || "request"} failed`, err);
  const { provider, ...publicDetails } = details;
  ws.send(JSON.stringify({ kind: "error", op, message: safeErrorMessage(op, err, { provider }), ...publicDetails }));
}

function handleMessage(ws: Bun.ServerWebSocket<WsData>, msg: any) {
  switch (msg.op) {
    case "start": {
      const prompt = String(msg.prompt ?? "").trim();
      if (!prompt) return;
      const requestId = typeof msg.requestId === "string" ? msg.requestId : undefined;
      const cwd = String(msg.cwd || DEFAULT_CWD);
      const title = prompt.length > 64 ? prompt.slice(0, 64) + "…" : prompt;
      const provider = String(msg.provider);
      const autoApprove = msg.autoApprove !== false;
      const rawOptions = applyAutoApproveDefaults(provider, autoApprove, parseOptions(msg.options));
      pruneStartRequests();
      const existing = requestId ? startRequests.get(requestId) : undefined;
      const startPromise = existing?.promise ?? Promise.resolve(assertCwd(cwd).then(() => sanitizeStartOptions(provider, cwd, rawOptions))).then((options) => {
        const sess = createSession(provider, cwd, autoApprove, title, options);
        refreshSession(sess);
        sendPrompt(sess, prompt);
        return sess;
      });
      if (requestId && !existing) {
        startRequests.set(requestId, { createdAt: Date.now(), promise: startPromise });
        startPromise.finally(() => {
          setTimeout(() => {
            if (startRequests.get(requestId)?.promise === startPromise) startRequests.delete(requestId);
          }, START_REQUEST_TTL_MS);
        }).catch(() => {});
      }
      startPromise.then((sess) => {
        subscribe(ws, sess);
        ws.send(JSON.stringify({ kind: "session-created", session: sessionSummary(sess), requestId }));
        if (existing) {
          ws.send(JSON.stringify({
            kind: "history",
            sessionId: sess.id,
            session: sessionSummary(sess),
            events: sess.events,
          }));
        }
      }).catch((err) => {
        sendWsErrorDetails(ws, "start", err, { provider, requestId });
      });
      break;
    }
    case "check-cwd": {
      const cwd = String(msg.cwd || DEFAULT_CWD);
      Promise.resolve(checkCwd(cwd))
        .then((res) => ws.send(JSON.stringify({ kind: "cwd-check", cwd, ...res })))
        .catch((err) => ws.send(JSON.stringify({ kind: "cwd-check", cwd, ok: false, message: String(err) })));
      break;
    }
    case "send": {
      const sess = sessions.get(String(msg.sessionId));
      const prompt = String(msg.prompt ?? "").trim();
      if (!sess || !prompt) return;
      sendPrompt(sess, prompt);
      break;
    }
    case "subscribe": {
      const sess = sessions.get(String(msg.sessionId));
      if (!sess) {
        ws.send(JSON.stringify({ kind: "no-session", sessionId: msg.sessionId }));
        return;
      }
      subscribe(ws, sess);
      ws.send(JSON.stringify({
        kind: "history",
        sessionId: sess.id,
        session: sessionSummary(sess),
        events: sess.events,
      }));
      refreshSession(sess);
      break;
    }
    case "stop": {
      const sess = sessions.get(String(msg.sessionId));
      sess?.adapter.stop(sess);
      break;
    }
    case "set-option": {
      const sess = sessions.get(String(msg.sessionId));
      const id = String(msg.id ?? "");
      const value = msg.value;
      if (!sess || !id || (typeof value !== "string" && typeof value !== "boolean")) return;
      Promise.resolve(sess.adapter.setOption(sess, id, value)).catch((err) => {
        console.error("[agent-chat] set-option failed", err);
        sess.emit({ kind: "error", message: safeErrorMessage("set-option", err) });
      });
      break;
    }
    case "fork": {
      const sess = sessions.get(String(msg.sessionId));
      if (!sess) {
        sendWsErrorDetails(ws, "fork", new Error("no session"), { sessionId: String(msg.sessionId ?? "") });
        return;
      }
      Promise.resolve(forkSession(sess))
        .then((fork) => ws.send(JSON.stringify({ kind: "session-forked", session: sessionSummary(fork) })))
        .catch((err) => {
          sess.emit({ kind: "error", message: safeErrorMessage("fork", err) });
          sendWsErrorDetails(ws, "fork", err, { sessionId: sess.id });
        });
      break;
    }
    case "list-options": {
      const provider = String(msg.provider ?? "");
      if (!adapters.has(provider)) {
        sendWsError(ws, "list-options", `unknown provider: ${provider}`);
        return;
      }
      const cwd = String(msg.cwd || DEFAULT_CWD);
      Promise.resolve(catalogOptions(provider, cwd))
        .then((options) => ws.send(JSON.stringify({ kind: "options-list", provider, options })))
        .catch((err) => sendWsError(ws, "list-options", err));
      break;
    }
    case "list-commands": {
      const provider = String(msg.provider ?? "");
      const adapter = adapters.get(provider);
      if (!adapter) {
        sendWsError(ws, "list-commands", `unknown provider: ${provider}`);
        return;
      }
      const cwd = String(msg.cwd || DEFAULT_CWD);
      Promise.resolve(cachedCommands(provider, cwd))
        .then((groups) => ws.send(JSON.stringify({ kind: "commands-list", provider, groups })))
        .catch((err) => sendWsError(ws, "list-commands", err));
      break;
    }
    case "list-files": {
      const cwd = String(msg.cwd || DEFAULT_CWD);
      Promise.resolve(cachedFiles(cwd))
        .then((files) => ws.send(JSON.stringify({ kind: "files-list", cwd, files })))
        .catch((err) => sendWsError(ws, "list-files", err));
      break;
    }
    case "get-file-diff": {
      const sess = sessions.get(String(msg.sessionId));
      const path = String(msg.path ?? "");
      if (!path) {
        sendWsErrorDetails(ws, "get-file-diff", new Error("invalid path"), { sessionId: String(msg.sessionId ?? ""), path });
        return;
      }
      if (!sess) {
        sendWsErrorDetails(ws, "get-file-diff", new Error("no session"), { sessionId: String(msg.sessionId ?? ""), path });
        return;
      }
      if (ws.data.subscribed !== sess.id) {
        sendWsErrorDetails(ws, "get-file-diff", new Error("no session"), { sessionId: sess.id, path });
        return;
      }
      let safePath: string;
      try {
        safePath = resolveFileDiffPath(sess.cwd, path);
        assertFileDiffAllowed(sess, safePath);
      } catch (err) {
        sendWsErrorDetails(ws, "get-file-diff", err, { sessionId: sess.id, path });
        return;
      }
      Promise.resolve(fileDiff(sess.cwd, safePath))
        .then((diff) => ws.send(JSON.stringify({ kind: "file-diff", sessionId: sess.id, path: safePath, diff })))
        .catch((err) => sendWsErrorDetails(ws, "get-file-diff", err, { sessionId: sess.id, path }));
      break;
    }
    case "delete": {
      const sess = sessions.get(String(msg.sessionId));
      if (!sess) return;
      sess.adapter.dispose(sess);
      sessions.delete(sess.id);
      broadcastSessions();
      break;
    }
  }
}

function subscribe(ws: Bun.ServerWebSocket<WsData>, sess: Session) {
  const prev = ws.data.subscribed;
  if (prev) sessions.get(prev)?.sockets.delete(ws);
  ws.data.subscribed = sess.id;
  sess.sockets.add(ws);
}

process.on("SIGINT", () => {
  for (const sess of sessions.values()) sess.adapter.dispose(sess);
  process.exit(0);
});

if (import.meta.main) startServer();
