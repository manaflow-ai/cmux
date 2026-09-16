// cmux-amp-session-extension-marker v3
// Bridges Amp thread lifecycle, title, and authoritative state into cmux.
// Installed and refreshed automatically by cmux's managed Amp wrapper.
// DO NOT EDIT MANUALLY. cmux upgrades this file in place.
// @i-know-the-amp-plugin-api-is-wip-and-very-experimental-right-now

import { spawn } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import type {
  PluginAPI,
  AgentEndEvent,
  AgentStartEvent,
  SessionStartEvent,
  ToolCallEvent,
  ToolResultEvent,
} from "@ampcode/plugin";

type AmpObservable = {
  get?: () => Promise<unknown> | unknown;
  subscribe?: (callback: (value: unknown) => void) => { unsubscribe?: () => void };
};

type AmpThread = {
  id?: string;
  state?: AmpObservable;
  title?: AmpObservable;
};

type AmpThreadContext = { thread?: AmpThread };

type AmpActiveThreadObservable = {
  current?: AmpThread | null;
  subscribe?: (callback: (value: unknown) => void) => { unsubscribe?: () => void };
};

type AmpThreads = {
  get?: (threadId: string) => AmpThread;
};

type AmpStatusPresentation = {
  label: string;
  icon: string;
  color: string;
};

function firstString(...values: unknown[]): string | null {
  for (const value of values) {
    if (typeof value === "string" && value.trim().length > 0) return value.trim();
  }
  return null;
}

function resolveExecutable(name: string): string {
  const pathEnv = process.env.PATH || "";
  for (const dir of pathEnv.split(path.delimiter)) {
    if (!dir) continue;
    const candidate = path.join(dir, name);
    if (isExecutableFile(candidate)) {
      return candidate;
    }
  }
  return name;
}

function hasCmuxTarget(): boolean {
  return Boolean(process.env.CMUX_SURFACE_ID || process.env.CMUX_WORKSPACE_ID);
}

function isExecutableFile(candidate: string): boolean {
  try {
    if (!fs.statSync(candidate).isFile()) return false;
    fs.accessSync(candidate, fs.constants.X_OK);
    return true;
  } catch (_) {
    return false;
  }
}

function cmuxBin(): string {
  const override = firstString(process.env.CMUX_AMP_CMUX_BIN);
  if (override) {
    if (isExecutableFile(override)) return override;
    // Preserve command-name overrides (for example `cmux`) by resolving them
    // through PATH, while still rejecting invalid directory/path overrides.
    if (!override.includes("/") && !override.includes("\\")) {
      const resolved = resolveExecutable(override);
      if (resolved !== override) return resolved;
    }
  }
  const bundled = firstString(process.env.CMUX_BUNDLED_CLI_PATH);
  if (bundled && isExecutableFile(bundled)) return bundled;
  return resolveExecutable("cmux");
}

function looksLikeAmpExecutable(value: string): boolean {
  return path.basename(value.replaceAll("\\", "/")).toLowerCase() === "amp";
}

function looksLikeAmpScript(value: string): boolean {
  const normalized = value.replaceAll("\\", "/");
  const segments = normalized.split("/").filter(Boolean).map((segment) => segment.toLowerCase());
  return segments.some((segment, index) => {
    if (segments[index + 1] === "amp"
      && (segment === "@ampcode" || segment === "@sourcegraph")) {
      return true;
    }
    return segment === "@ampcode"
      && segments[index + 1] === "cli"
      && segments[index + 2] === "cli-wrapper.cjs";
  });
}

function looksLikeJavaScriptRuntime(value: string): boolean {
  const base = path.basename(value.replaceAll("\\", "/")).toLowerCase();
  return base === "node" || base === "bun" || base === "deno" || base === "tsx" || base === "ts-node";
}

function normalizedLaunchArgv(): string[] {
  const raw = Array.isArray(process.argv) ? process.argv.map((value) => String(value)) : [];
  if (raw.length === 0) return [resolveExecutable("amp")];
  if (looksLikeAmpExecutable(raw[0])) return raw;
  if (looksLikeAmpScript(raw[0])) {
    return [resolveExecutable("amp"), ...raw.slice(1)];
  }
  if (raw.length > 1 && looksLikeJavaScriptRuntime(raw[0])) {
    if (!looksLikeAmpScript(raw[1])) return raw;
    return [resolveExecutable("amp"), ...raw.slice(2)];
  }
  // An unrecognized argv is more trustworthy than a path heuristic. Preserve
  // it verbatim so custom launchers and their arguments remain restorable.
  return raw;
}

function base64NulSeparated(values: string[]): string {
  const bytes: Buffer[] = [];
  for (const value of values) {
    bytes.push(Buffer.from(String(value), "utf8"));
    bytes.push(Buffer.from([0]));
  }
  return Buffer.concat(bytes).toString("base64");
}

function hookEnvironment(cwd: string): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = { ...process.env };
  delete env.AMP_API_KEY;
  env.CMUX_AMP_PID ||= String(process.pid);
  if (!env.CMUX_AGENT_LAUNCH_ARGV_B64) {
    const argv = normalizedLaunchArgv();
    env.CMUX_AGENT_LAUNCH_KIND = "amp";
    env.CMUX_AGENT_LAUNCH_EXECUTABLE = argv[0] || resolveExecutable("amp");
    env.CMUX_AGENT_LAUNCH_ARGV_B64 = base64NulSeparated(argv);
    env.CMUX_AGENT_LAUNCH_CWD = cwd || process.cwd();
  }
  return env;
}

function eventName(subcommand: string): string {
  switch (subcommand) {
    case "session-start": return "SessionStart";
    case "prompt-submit": return "UserPromptSubmit";
    case "title-update": return "TitleUpdate";
    case "lifecycle": return "Lifecycle";
    default: return subcommand;
  }
}

function sendHook(
  subcommand: string,
  sessionId: string,
  cwd: string,
  extra: Record<string, unknown> = {},
): void {
  if (process.env.CMUX_AMP_HOOKS_DISABLED === "1") return;
  if (!hasCmuxTarget() || !sessionId) return;
  const payload: Record<string, unknown> = {
    session_id: sessionId,
    cwd,
    hook_event_name: eventName(subcommand),
    event: eventName(subcommand),
    ...extra,
  };
  try {
    const child = spawn(cmuxBin(), ["hooks", "enqueue", "amp", subcommand], {
      env: { ...hookEnvironment(cwd), CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC: "1" },
      stdio: ["pipe", "ignore", "ignore"],
      detached: true,
    });
    child.on("error", () => {});
    child.stdin.on("error", () => {});
    child.stdin.end(JSON.stringify(payload));
    child.unref();
  } catch (_) {}
}

const STATUS_KEY = "amp";
const LOG_SOURCE = "amp";
const COLOR = {
  idle: "#adb5bd",
  thinking: "#ffffff",
  active: "#ffd700",
  needsInput: "#4C8DFF",
  done: "#50fa7b",
  error: "#ff5555",
  interrupted: "#ffb86c",
} as const;

const PRESENTATION = {
  idle: { label: "__cmux_amp_status_idle", icon: "circle", color: COLOR.idle },
  thinking: { label: "__cmux_amp_status_thinking", icon: "brain", color: COLOR.thinking },
  needsInput: { label: "__cmux_amp_status_needs_input", icon: "bell.fill", color: COLOR.needsInput },
  done: { label: "__cmux_amp_status_done", icon: "checkmark.circle", color: COLOR.done },
  error: { label: "__cmux_amp_status_error", icon: "xmark.circle", color: COLOR.error },
  interrupted: { label: "__cmux_amp_status_interrupted", icon: "pause.circle", color: COLOR.interrupted },
} as const satisfies Record<string, AmpStatusPresentation>;

function workspaceArgs(): string[] {
  const workspace = process.env.CMUX_WORKSPACE_ID;
  return workspace ? ["--workspace", workspace] : [];
}

function runCmux(args: string[]): void {
  if (process.env.CMUX_AMP_HOOKS_DISABLED === "1" || !hasCmuxTarget()) return;
  const env: NodeJS.ProcessEnv = { ...process.env };
  delete env.AMP_API_KEY;
  try {
    const child = spawn(cmuxBin(), args, {
      env,
      stdio: ["ignore", "ignore", "ignore"],
      detached: true,
    });
    child.on("error", () => {});
    child.unref();
  } catch (_) {}
}

function setStatus(label: string, icon: string, color: string): void {
  runCmux(["set-status", STATUS_KEY, label, "--icon", icon, "--color", color, ...workspaceArgs()]);
}

function clearStatus(): void {
  runCmux(["clear-status", STATUS_KEY, ...workspaceArgs()]);
}

function wsLog(message: string, level: string = "info"): void {
  runCmux(["log", "--level", level, "--source", LOG_SOURCE, ...workspaceArgs(), "--", message]);
}

function toolLabel(tool: string): string {
  switch (tool) {
    case "Read": return "reading";
    case "edit_file":
    case "create_file": return "editing";
    case "Bash": return "running";
    case "Grep":
    case "finder":
    case "glob": return "searching";
    case "Task": return "subagent";
    case "oracle": return "consulting oracle";
    case "web_search":
    case "read_web_page": return "browsing";
    case "mermaid": return "diagramming";
    case "handoff": return "handing off";
    case "skill": return "loading skill";
    case "todo_write":
    case "todo_read": return "planning";
    default: return tool;
  }
}

function toolIcon(tool: string): string {
  switch (tool) {
    case "Read": return "eye";
    case "edit_file":
    case "create_file": return "pencil";
    case "Bash": return "terminal";
    case "Grep":
    case "finder":
    case "glob": return "magnifyingglass";
    case "Task": return "person.2";
    case "oracle": return "sparkles";
    case "web_search":
    case "read_web_page": return "globe";
    case "todo_write":
    case "todo_read": return "checklist";
    default: return "hammer";
  }
}

function truncate(value: string, max: number): string {
  return value.length > max ? value.slice(0, max - 1) + "…" : value;
}

function basename(value: string): string {
  const match = value.match(/[^/]+$/);
  return match ? match[0] : value;
}

function detailedToolStatus(event: ToolCallEvent, helpers: unknown): { label: string; icon: string } {
  const baseLabel = toolLabel(event.tool);
  const icon = toolIcon(event.tool);
  const h = helpers as {
    shellCommandFromToolCall?: (event: ToolCallEvent) => { command: string } | null;
    filesModifiedByToolCall?: (event: ToolCallEvent) => string[] | null;
    filePathFromURI?: (uri: string) => string;
  } | undefined;
  try {
    const shell = h?.shellCommandFromToolCall?.(event);
    if (shell && typeof shell.command === "string") {
      return { label: `${baseLabel}: ${truncate(shell.command.replace(/\s+/g, " ").trim(), 32)}`, icon };
    }
  } catch (_) {}
  try {
    const files = h?.filesModifiedByToolCall?.(event);
    if (files && files.length > 0) {
      const file = h?.filePathFromURI ? h.filePathFromURI(files[0]) : files[0];
      return { label: `${baseLabel}: ${truncate(basename(file), 24)}`, icon };
    }
  } catch (_) {}
  if (event.tool === "Read") {
    const file = (event.input as { path?: unknown }).path;
    if (typeof file === "string") return { label: `${baseLabel}: ${truncate(basename(file), 24)}`, icon };
  }
  if (event.tool === "Grep" || event.tool === "glob") {
    const input = event.input as { pattern?: unknown; query?: unknown };
    const pattern = typeof input.pattern === "string"
      ? input.pattern
      : typeof input.query === "string" ? input.query : null;
    if (pattern) return { label: `${baseLabel}: ${truncate(pattern, 24)}`, icon };
  }
  return { label: baseLabel, icon };
}


export default function (amp: PluginAPI) {
  const rootThread = (amp as unknown as { thread?: AmpThread }).thread;
  const helpers = (amp as unknown as { helpers?: unknown }).helpers;
  // Amp executes plugin callbacks from the system plugin directory. The
  // managed wrapper captures the terminal's project directory explicitly;
  // use that trusted value and fall back to the process cwd for older launches.
  const cwdFromEnv = (): string => firstString(
    process.env.CMUX_AGENT_LAUNCH_CWD,
    process.cwd(),
  ) || process.cwd();
  const titleByThread = new Map<string, string>();
  const emittedTitleByThread = new Map<string, string>();
  const titleVersions = new Map<string, number>();
  const titleLookupTokens = new Map<string, number>();
  const observedTitleThreads = new Set<string>();
  const titleSubscriptions = new Map<string, { unsubscribe?: () => void }>();
  const stateSubscriptions = new Map<string, { unsubscribe?: () => void }>();
  const resumableStateSubscriptions = new Map<string, { unsubscribe?: () => void }>();
  const resumableSubscriptionOrder = new Map<string, number>();
  const evictedLifecycleSnapshots = new Map<string, AmpThreadLifecycle>();
  const evictedLifecycleOrder = new Map<string, number>();
  const threadById = new Map<string, AmpThread>();
  const MAX_TRACKED_THREADS = 128;
  const threadTouchOrder = new Map<string, number>();
  let threadTouchSequence = 0;
  let titleLookupSequence = 0;
  let resumableSubscriptionSequence = 0;
  let evictedLifecycleSequence = 0;
  type AmpThreadLifecycle = {
    authoritativeState: string;
    observationVersion: number;
    stateReadVersion: number;
    turnStateStartVersion: number;
    inFlightTools: number;
    presentation: AmpStatusPresentation;
    pendingTurn: {
      outcome: string;
      turnId: string | null;
      assistantMessage: string | null;
    } | null;
    terminalEventEmitted: boolean;
    activeTurnId: string | null;
  };
  const lifecycleByThread = new Map<string, AmpThreadLifecycle>();
  const activeThread = (amp as unknown as {
    activeThread?: AmpActiveThreadObservable;
  }).activeThread;
  const threads = (amp as unknown as { threads?: AmpThreads }).threads;
  let presentedThreadId = firstString(activeThread?.current?.id);
  const TITLE_MAX_LENGTH = 200;
  function touchThread(threadId: string): void {
    threadTouchOrder.delete(threadId);
    threadTouchOrder.set(threadId, ++threadTouchSequence);
  }
  function invalidateThreadObservers(threadId: string): void {
    try { titleSubscriptions.get(threadId)?.unsubscribe?.(); } catch (_) {}
    try { stateSubscriptions.get(threadId)?.unsubscribe?.(); } catch (_) {}
    try { resumableStateSubscriptions.get(threadId)?.unsubscribe?.(); } catch (_) {}
    titleSubscriptions.delete(threadId);
    stateSubscriptions.delete(threadId);
    resumableStateSubscriptions.delete(threadId);
    resumableSubscriptionOrder.delete(threadId);
    observedTitleThreads.delete(threadId);
    titleLookupTokens.set(threadId, (titleLookupTokens.get(threadId) || 0) + 1);
    const lifecycle = lifecycleByThread.get(threadId);
    if (lifecycle) {
      // Invalidate reads and callbacks that belong to the replaced Amp object.
      lifecycle.stateReadVersion += 1;
      lifecycle.observationVersion += 1;
    }
  }
  function rememberThread(threadId: string, thread: AmpThread): AmpThread {
    const previous = threadById.get(threadId);
    const hasObservable = Boolean(thread.state || thread.title);
    if (previous && previous !== thread && hasObservable) {
      invalidateThreadObservers(threadId);
    }
    // A sparse event context must not replace a richer active-thread handle.
    if (previous && previous !== thread && !hasObservable) return previous;
    threadById.set(threadId, thread);
    return thread;
  }
  function retainResumableSubscription(threadId: string, subscription: { unsubscribe?: () => void }): void {
    resumableStateSubscriptions.set(threadId, subscription);
    resumableSubscriptionOrder.delete(threadId);
    resumableSubscriptionOrder.set(threadId, ++resumableSubscriptionSequence);
    while (resumableStateSubscriptions.size > MAX_TRACKED_THREADS) {
      const oldest = resumableSubscriptionOrder.keys().next().value as string | undefined;
      if (!oldest) break;
      try { resumableStateSubscriptions.get(oldest)?.unsubscribe?.(); } catch (_) {}
      resumableStateSubscriptions.delete(oldest);
      resumableSubscriptionOrder.delete(oldest);
      evictedLifecycleSnapshots.delete(oldest);
      evictedLifecycleOrder.delete(oldest);
    }
  }
  function restoreResumableSubscription(threadId: string): boolean {
    const subscription = resumableStateSubscriptions.get(threadId);
    if (!subscription) return false;
    resumableStateSubscriptions.delete(threadId);
    resumableSubscriptionOrder.delete(threadId);
    stateSubscriptions.set(threadId, subscription);
    return true;
  }
  function retainLifecycleSnapshot(threadId: string, lifecycle: AmpThreadLifecycle): void {
    evictedLifecycleSnapshots.set(threadId, { ...lifecycle, pendingTurn: lifecycle.pendingTurn ? { ...lifecycle.pendingTurn } : null });
    evictedLifecycleOrder.delete(threadId);
    evictedLifecycleOrder.set(threadId, ++evictedLifecycleSequence);
    while (evictedLifecycleSnapshots.size > MAX_TRACKED_THREADS) {
      const oldest = evictedLifecycleOrder.keys().next().value as string | undefined;
      if (!oldest) break;
      evictedLifecycleSnapshots.delete(oldest);
      evictedLifecycleOrder.delete(oldest);
      try { resumableStateSubscriptions.get(oldest)?.unsubscribe?.(); } catch (_) {}
      resumableStateSubscriptions.delete(oldest);
      resumableSubscriptionOrder.delete(oldest);
    }
  }
  function forgetThread(threadId: string): void {
    const lifecycle = lifecycleByThread.get(threadId);
    if (lifecycle) retainLifecycleSnapshot(threadId, lifecycle);
    try { titleSubscriptions.get(threadId)?.unsubscribe?.(); } catch (_) {}
    const stateSubscription = stateSubscriptions.get(threadId);
    if (stateSubscription && lifecycle && evictedLifecycleSnapshots.has(threadId)) {
      retainResumableSubscription(threadId, stateSubscription);
    } else if (stateSubscription) {
      try { stateSubscription.unsubscribe?.(); } catch (_) {}
    }
    titleSubscriptions.delete(threadId);
    stateSubscriptions.delete(threadId);
    titleByThread.delete(threadId);
    emittedTitleByThread.delete(threadId);
    titleVersions.delete(threadId);
    titleLookupTokens.set(threadId, (titleLookupTokens.get(threadId) || 0) + 1);
    observedTitleThreads.delete(threadId);
    threadById.delete(threadId);
    lifecycleByThread.delete(threadId);
    threadTouchOrder.delete(threadId);
    while (titleLookupTokens.size > MAX_TRACKED_THREADS * 2) {
      const stale = [...titleLookupTokens.keys()].find((id) => !threadTouchOrder.has(id));
      if (!stale) break;
      titleLookupTokens.delete(stale);
    }
  }
  function evictInactiveThread(): boolean {
    const inactive = [...threadTouchOrder.keys()].find((threadId) => { if (threadId === presentedThreadId) return false; const lifecycle = lifecycleByThread.get(threadId); return lifecycle && !["running", "awaiting-approval", "needs-input"].includes(lifecycle.authoritativeState) && !lifecycle.pendingTurn; });
    if (!inactive) return false;
    forgetThread(inactive);
    return true;
  }
  function evictOldestThread(): boolean {
    const oldest = [...threadTouchOrder.keys()].find((threadId) => threadId !== presentedThreadId);
    if (!oldest) return false;
    forgetThread(oldest);
    return true;
  }
  function pruneThreadState(): void {
    while (lifecycleByThread.size > MAX_TRACKED_THREADS && evictInactiveThread()) {}
  }
  function threadFrom(event: { thread?: AmpThread } | undefined, ctx?: AmpThreadContext): AmpThread | undefined {
    const thread = ctx?.thread || event?.thread || rootThread;
    const threadId = firstString(thread?.id);
    if (thread && threadId) {
      // Event payloads are commonly sparse `{ id }` views. Do not replace a
      // richer handle (and its observers) with that view.
      if (!threadById.has(threadId) || thread.state || thread.title) {
        threadById.set(threadId, thread);
      }
    }
    return thread;
  }
  function threadIdFrom(event: { thread?: AmpThread } | undefined, ctx?: AmpThreadContext): string | null {
    return firstString(event?.thread?.id, ctx?.thread?.id, rootThread?.id);
  }
  function lifecycleFor(threadId: string): AmpThreadLifecycle | null {
    const existing = lifecycleByThread.get(threadId);
    if (existing) {
      touchThread(threadId);
      return existing;
    }
    while (lifecycleByThread.size >= MAX_TRACKED_THREADS && evictInactiveThread()) {}
    // Every tracked thread may be active. Keep the newly observed thread
    // serviceable by evicting the oldest non-presented snapshot; its state and
    // subscription are retained by the bounded resumable caches.
    if (lifecycleByThread.size >= MAX_TRACKED_THREADS) {
      evictOldestThread();
    }
    if (lifecycleByThread.size >= MAX_TRACKED_THREADS) return null;
    const restored = evictedLifecycleSnapshots.get(threadId);
    if (restored) {
      evictedLifecycleSnapshots.delete(threadId);
      evictedLifecycleOrder.delete(threadId);
      lifecycleByThread.set(threadId, restored);
      touchThread(threadId);
      return restored;
    }
    const created: AmpThreadLifecycle = {
      authoritativeState: "idle",
      observationVersion: 0,
      stateReadVersion: 0,
      turnStateStartVersion: 0,
      inFlightTools: 0,
      presentation: PRESENTATION.idle,
      pendingTurn: null,
      terminalEventEmitted: false,
      activeTurnId: null,
    };
    lifecycleByThread.set(threadId, created);
    touchThread(threadId);
    pruneThreadState();
    return created;
  }
  function isPresentedThread(threadId: string): boolean {
    return activeThread ? presentedThreadId === threadId : true;
  }
  function projectThreadPresentation(threadId: string): void {
    if (!isPresentedThread(threadId)) return;
    const lifecycle = lifecycleFor(threadId);
    if (!lifecycle) return;
    const presentation = lifecycle.presentation;
    setStatus(presentation.label, presentation.icon, presentation.color);
  }
  function updateThreadPresentation(
    threadId: string,
    presentation: AmpStatusPresentation,
  ): void {
    const lifecycle = lifecycleFor(threadId);
    if (!lifecycle) return;
    lifecycle.presentation = presentation;
    projectThreadPresentation(threadId);
  }
  function normalizedTurnId(value: unknown): string | null {
    if (typeof value === "number" && Number.isFinite(value)) return String(value);
    return firstString(value);
  }
  function lastAssistantMessage(event: AgentEndEvent): string | null {
    const messages = Array.isArray(event.messages) ? event.messages : [];
    for (let index = messages.length - 1; index >= 0; index -= 1) {
      const message = messages[index] as {
        role?: unknown;
        content?: Array<{ type?: unknown; text?: unknown }>;
      };
      if (message.role !== "assistant" || !Array.isArray(message.content)) continue;
      const text = message.content
        .filter((block) => block?.type === "text" && typeof block.text === "string")
        .map((block) => String(block.text))
        .join("\n")
        .trim();
      if (text) return text.slice(0, 1000);
    }
    return null;
  }
  function turnPayload(
    lifecycle: AmpThreadLifecycle,
    pending = lifecycle.pendingTurn,
  ): Record<string, unknown> {
    const turnId = pending?.turnId || lifecycle.activeTurnId;
    const assistantMessage = pending?.assistantMessage;
    return {
      ...(turnId ? { turn_id: turnId } : {}),
      ...(assistantMessage ? { last_assistant_message: assistantMessage } : {}),
    };
  }
  function normalizedTitle(value: unknown): string | null {
    const raw = typeof value === "string"
      ? value
      : firstString((value as { value?: unknown } | null)?.value);
    if (!raw) return null;
    const title = raw.slice(0, TITLE_MAX_LENGTH * 2).replace(/\s+/g, " ").trim();
    if (!title) return null;
    return title.length > TITLE_MAX_LENGTH ? title.slice(0, TITLE_MAX_LENGTH - 1) + "…" : title;
  }
  function titleExtra(threadId: string): Record<string, unknown> {
    const title = titleByThread.get(threadId);
    return title ? { title } : {};
  }
  function rememberTitle(threadId: string, value: unknown): string | null {
    const title = normalizedTitle(value);
    if (!title) return null;
    if (titleByThread.get(threadId) === title) return title;
    titleByThread.set(threadId, title);
    titleVersions.set(threadId, (titleVersions.get(threadId) || 0) + 1);
    return title;
  }
  function beginTitleLookup(threadId: string): number {
    const token = ++titleLookupSequence;
    titleLookupTokens.set(threadId, token);
    return token;
  }
  function fallbackTitleFromAgentStart(event: AgentStartEvent): string | null {
    return normalizedTitle((event as unknown as { message?: unknown }).message);
  }
  function emitTitle(threadId: string, title: string): void {
    if (emittedTitleByThread.get(threadId) === title) return;
    emittedTitleByThread.set(threadId, title);
    sendHook("title-update", threadId, cwdFromEnv(), { title });
  }
  function resolveThreadTitle(threadId: string, thread?: AmpThread): void {
    if (!thread?.title?.get) return;
    const token = beginTitleLookup(threadId);
    const startVersion = titleVersions.get(threadId) || 0;
    let lookup: Promise<unknown> | unknown;
    try {
      lookup = thread.title.get();
    } catch (_) {
      return;
    }
    void Promise.resolve(lookup)
      .then((value) => {
        if (titleLookupTokens.get(threadId) !== token) return;
        if ((titleVersions.get(threadId) || 0) !== startVersion) return;
        if (threadById.get(threadId) !== thread) return;
        const candidate = normalizedTitle(value);
        if (!candidate) return;
        if (observedTitleThreads.has(threadId) && titleByThread.get(threadId) !== candidate) return;
        const title = rememberTitle(threadId, candidate);
        if (title) emitTitle(threadId, title);
      })
      .catch(() => {});
  }
  function watchThreadTitle(threadId: string, thread?: AmpThread): void {
    const observable = thread?.title;
    if (!observable?.subscribe || titleSubscriptions.has(threadId)) return;
    try {
      const observedThread = thread;
      const subscription = observable.subscribe((value) => {
        if (threadById.get(threadId) !== observedThread) return;
        const title = rememberTitle(threadId, value);
        if (!title) return;
        observedTitleThreads.add(threadId);
        emitTitle(threadId, title);
      });
      titleSubscriptions.set(threadId, {
        unsubscribe: () => subscription.unsubscribe?.(),
      });
    } catch (_) {}
  }
  function normalizedThreadState(value: unknown): string | null {
    const raw = typeof value === "string"
      ? value
      : firstString(
          (value as { state?: unknown } | null)?.state,
          (value as { value?: unknown } | null)?.value,
        );
    if (!raw) return null;
    switch (raw.toLowerCase().replaceAll("_", "-")) {
      case "running":
      case "thinking":
      case "working":
        return "running";
      case "awaiting-approval":
      case "awaiting-input":
      case "needs-input":
      case "blocked":
        return "awaiting-approval";
      case "idle":
      case "done":
      case "complete":
      case "completed":
        return "idle";
      case "error":
      case "failed":
        return "error";
      default:
        return null;
    }
  }
  function normalizedTurnOutcome(value: unknown): string {
    switch (String(value || "done").toLowerCase()) {
      case "error":
      case "failed": return "error";
      case "cancelled":
      case "canceled":
      case "interrupted": return "cancelled";
      default: return "done";
    }
  }
  function reconcileThreadState(threadId: string, value: unknown): void {
    const state = normalizedThreadState(value);
    if (!state) return;
    const lifecycle = lifecycleFor(threadId);
    if (!lifecycle) return;
    lifecycle.authoritativeState = state;
    const cwd = cwdFromEnv();
    switch (state) {
      case "running":
        lifecycle.terminalEventEmitted = false;
        if (lifecycle.inFlightTools === 0) {
          updateThreadPresentation(threadId, PRESENTATION.thinking);
        } else {
          projectThreadPresentation(threadId);
        }
        sendHook("lifecycle", threadId, cwd, {
          agent_state: state,
          ...turnPayload(lifecycle),
        });
        break;
      case "awaiting-approval":
        lifecycle.inFlightTools = 0;
        updateThreadPresentation(threadId, PRESENTATION.needsInput);
        sendHook("lifecycle", threadId, cwd, {
          agent_state: state,
          notification_type: "permission_prompt",
          ...turnPayload(lifecycle),
        });
        break;
      case "idle": {
        const pending = lifecycle.pendingTurn;
        if (!pending) {
          lifecycle.inFlightTools = 0;
          if (!lifecycle.terminalEventEmitted) {
            updateThreadPresentation(threadId, PRESENTATION.idle);
          }
          break;
        }
        lifecycle.inFlightTools = 0;
        lifecycle.pendingTurn = null;
        if (lifecycle.terminalEventEmitted) break;
        lifecycle.terminalEventEmitted = true;
        const outcome = pending.outcome;
        if (outcome === "done") {
          updateThreadPresentation(threadId, PRESENTATION.done);
          wsLog("turn complete", "success");
        } else if (outcome === "cancelled") {
          updateThreadPresentation(threadId, PRESENTATION.interrupted);
          wsLog("turn interrupted", "warning");
        } else {
          updateThreadPresentation(threadId, PRESENTATION.error);
          wsLog("turn errored", "error");
        }
        sendHook("lifecycle", threadId, cwd, {
          agent_state: state,
          turn_outcome: outcome,
          ...turnPayload(lifecycle, pending),
          ...(outcome === "error" ? {
            notification_type: "error",
          } : {}),
        });
        lifecycle.activeTurnId = null;
        break;
      }
      case "error": {
        const pending = lifecycle.pendingTurn;
        const outcome = pending?.outcome === "cancelled" ? "cancelled" : "error";
        lifecycle.inFlightTools = 0;
        lifecycle.pendingTurn = null;
        if (lifecycle.terminalEventEmitted) break;
        lifecycle.terminalEventEmitted = true;
        updateThreadPresentation(threadId, PRESENTATION.error);
        wsLog("turn errored", "error");
        sendHook("lifecycle", threadId, cwd, {
          agent_state: state,
          turn_outcome: outcome,
          notification_type: "error",
          ...turnPayload(lifecycle, pending),
        });
        lifecycle.activeTurnId = null;
        break;
      }
    }
  }
  function refreshThreadState(threadId: string, thread?: AmpThread): void {
    const observable = thread?.state;
    if (!observable?.get) return;
    const lifecycle = lifecycleFor(threadId);
    if (!lifecycle) return;
    const version = ++lifecycle.stateReadVersion;
    let lookup: Promise<unknown> | unknown;
    try {
      lookup = observable.get();
    } catch (_) {
      return;
    }
    void Promise.resolve(lookup)
      .then((value) => {
        const current = lifecycleByThread.get(threadId);
        if (current === lifecycle
          && version === current.stateReadVersion
          && (!thread || threadById.get(threadId) === thread)) {
          reconcileThreadState(threadId, value);
        }
      })
      .catch(() => {});
  }
  function watchThreadState(threadId: string, thread?: AmpThread): void {
    const observable = thread?.state;
    if (!observable) return;
    if (!lifecycleFor(threadId)) return;
    const restoredSubscription = restoreResumableSubscription(threadId);
    const alreadySubscribed = stateSubscriptions.has(threadId);
    if (observable.subscribe && !alreadySubscribed) {
      try {
        const observedThread = thread;
        const subscription = observable.subscribe((value) => {
          if (observedThread && threadById.get(threadId) !== observedThread) return;
          const lifecycle = lifecycleByThread.get(threadId) || lifecycleFor(threadId);
          if (!lifecycle) return;
          restoreResumableSubscription(threadId);
          lifecycle.stateReadVersion += 1;
          lifecycle.observationVersion += 1;
          reconcileThreadState(threadId, value);
        });
        stateSubscriptions.set(threadId, { unsubscribe: () => subscription.unsubscribe?.() });
      } catch (_) {}
    }
    if (restoredSubscription || !alreadySubscribed || !stateSubscriptions.has(threadId)) {
      refreshThreadState(threadId, thread);
    }
  }
  function hasThreadStateCapability(thread?: AmpThread): boolean {
    return typeof thread?.state?.get === "function"
      || typeof thread?.state?.subscribe === "function";
  }
  function threadFromActiveValue(value: unknown): AmpThread | undefined {
    const wrapped = value as {
      current?: AmpThread | null;
      value?: AmpThread | null;
      thread?: AmpThread | null;
    } | null;
    const directCandidate = value && typeof value === "object" && firstString((value as AmpThread).id)
      ? value as AmpThread
      : undefined;
    const wrappedCandidate = wrapped?.current || wrapped?.value || wrapped?.thread || undefined;
    const activeCandidate = activeThread?.current || undefined;
    const candidate = directCandidate || wrappedCandidate;
    const threadId = firstString(
      value,
      candidate?.id,
      activeCandidate?.id,
      threadById.get(firstString(value) || "")?.id,
    );
    if (!threadId) return undefined;
    // The active observable (or its wrapper) is authoritative for the current
    // selection. Sparse active values need a fresh full handle from
    // `threads.get`; otherwise a same-ID replacement could inherit stale
    // state/title observers from the bounded cache.
    if (candidate
      && firstString(candidate.id) === threadId
      && (candidate.state || candidate.title)) return candidate;
    try {
      const resolved = threads?.get?.(threadId);
      if (resolved) return resolved;
    } catch (_) {}
    if (activeCandidate && firstString(activeCandidate.id) === threadId) return activeCandidate;
    return threadById.get(threadId);
  }
  function reconcileActiveThread(value: unknown): void {
    const thread = threadFromActiveValue(value);
    const threadId = firstString(value, thread?.id, activeThread?.current?.id);
    if (!threadId) {
      presentedThreadId = null;
      clearStatus();
      return;
    }
    presentedThreadId = threadId;
    const lifecycle = lifecycleFor(threadId);
    if (!lifecycle) {
      presentedThreadId = null;
      clearStatus();
      return;
    }
    const previous = threadById.get(threadId);
    const boundThread = thread ? rememberThread(threadId, thread) : previous;
    watchThreadTitle(threadId, boundThread);
    watchThreadState(threadId, boundThread);
    if (boundThread && boundThread !== previous) resolveThreadTitle(threadId, boundThread);
    projectThreadPresentation(threadId);
  }
  const activeThreadSubscription = (() => {
    if (activeThread) {
      try { reconcileActiveThread(activeThread.current); } catch (_) {}
    }
    if (!activeThread?.subscribe) return null;
    try {
      return activeThread.subscribe(reconcileActiveThread);
    } catch (_) {
      return null;
    }
  })();

  process.on("exit", () => {
    try { clearStatus(); } catch (_) {}
    try { activeThreadSubscription?.unsubscribe?.(); } catch (_) {}
    for (const subscription of titleSubscriptions.values()) {
      try { subscription.unsubscribe?.(); } catch (_) {}
    }
    for (const subscription of stateSubscriptions.values()) {
      try { subscription.unsubscribe?.(); } catch (_) {}
    }
    for (const subscription of resumableStateSubscriptions.values()) {
      try { subscription.unsubscribe?.(); } catch (_) {}
    }
  });

  amp.on("session.start", async (event: SessionStartEvent, ctx) => {
    const sessionId = threadIdFrom(event, ctx);
    if (!sessionId) return;
    const lifecycle = lifecycleFor(sessionId);
    if (!lifecycle) return;
    lifecycle.presentation = PRESENTATION.idle;
    const thread = threadFrom(event, ctx);
    watchThreadTitle(sessionId, thread);
    watchThreadState(sessionId, thread);
    projectThreadPresentation(sessionId);
    sendHook("session-start", sessionId, cwdFromEnv(), titleExtra(sessionId));
    resolveThreadTitle(sessionId, thread);
  });

  amp.on("agent.start", async (event: AgentStartEvent, ctx) => {
    wsLog("prompt received");
    const sessionId = threadIdFrom(event, ctx);
    if (!sessionId) return;
    const lifecycle = lifecycleFor(sessionId);
    if (!lifecycle) return;
    lifecycle.stateReadVersion += 1;
    lifecycle.observationVersion += 1;
    lifecycle.turnStateStartVersion = lifecycle.observationVersion;
    lifecycle.authoritativeState = "running";
    lifecycle.inFlightTools = 0;
    lifecycle.pendingTurn = null;
    lifecycle.terminalEventEmitted = false;
    lifecycle.activeTurnId = normalizedTurnId(event.id);
    updateThreadPresentation(sessionId, PRESENTATION.thinking);
    const thread = threadFrom(event, ctx);
    watchThreadTitle(sessionId, thread);
    watchThreadState(sessionId, thread);
    if (!titleByThread.has(sessionId)) {
      rememberTitle(sessionId, fallbackTitleFromAgentStart(event));
    }
    sendHook("prompt-submit", sessionId, cwdFromEnv(), {
      ...titleExtra(sessionId),
      ...turnPayload(lifecycle),
      prompt: event.message,
    });
    resolveThreadTitle(sessionId, thread);
  });

  amp.on("tool.call", async (event: ToolCallEvent) => {
    const sessionId = firstString(event.thread?.id);
    if (sessionId) {
      const lifecycle = lifecycleFor(sessionId);
      if (lifecycle?.authoritativeState === "running") {
        lifecycle.inFlightTools += 1;
        const { label, icon } = detailedToolStatus(event, helpers);
        updateThreadPresentation(sessionId, { label, icon, color: COLOR.active });
      }
    }
    // Request handlers must return a result. Amp gathers every plugin result and
    // gives error/reject/synthesize/modify outcomes precedence over `allow`.
    return { action: "allow" as const };
  });

  amp.on("tool.result", async (event: ToolResultEvent) => {
    if (event.status === "error") wsLog(`${event.tool} failed`, "error");
    const sessionId = firstString(event.thread?.id);
    if (!sessionId) return;
    const lifecycle = lifecycleFor(sessionId);
    if (!lifecycle) return;
    if (lifecycle.authoritativeState !== "running") return;
    lifecycle.inFlightTools = Math.max(0, lifecycle.inFlightTools - 1);
    if (lifecycle.inFlightTools === 0) {
      updateThreadPresentation(sessionId, PRESENTATION.thinking);
    }
  });

  amp.on("agent.end", async (event: AgentEndEvent, ctx) => {
    const sessionId = threadIdFrom(event, ctx);
    if (!sessionId) return;
    const lifecycle = lifecycleFor(sessionId);
    if (!lifecycle) return;
    lifecycle.inFlightTools = 0;
    lifecycle.pendingTurn = {
      outcome: normalizedTurnOutcome(event.status),
      turnId: normalizedTurnId(event.id) || lifecycle.activeTurnId,
      assistantMessage: lastAssistantMessage(event),
    };
    if (lifecycle.authoritativeState === "running") {
      updateThreadPresentation(sessionId, PRESENTATION.thinking);
    }
    const thread = threadFrom(event, ctx);
    resolveThreadTitle(sessionId, thread);
    // When available, authoritative thread.state owns completion so a lagging
    // agent.end/tool.result cannot race needs-input or a still-running process.
    // Older Amp releases expose no state observable, so agent.end is their
    // canonical terminal signal and reconciles through the same lifecycle hook.
    if (!hasThreadStateCapability(thread)) {
      reconcileThreadState(
        sessionId,
        lifecycle.pendingTurn?.outcome === "error" ? "error" : "idle",
      );
    } else if (lifecycle.terminalEventEmitted) {
      lifecycle.pendingTurn = null;
    } else if (
      lifecycle.observationVersion > lifecycle.turnStateStartVersion
      && (lifecycle.authoritativeState === "idle" || lifecycle.authoritativeState === "error")
    ) {
      reconcileThreadState(sessionId, lifecycle.authoritativeState);
    } else {
      refreshThreadState(sessionId, thread);
    }
  });
}
