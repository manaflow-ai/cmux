import Foundation
import Darwin

extension CMUXCLI {
    private static let ampExtensionMarker = "cmux-amp-session-extension-marker"
    private static let ampExtensionFilename = "cmux-session.ts"
    private static let ampExtensionSource = #"""
// cmux-amp-session-extension-marker v3
// Bridges Amp session lifecycle events into cmux's restorable session store
// AND reports live agent status (idle/thinking/tool calls/done/error) into
// the cmux tab status bar.
// Installed by `cmux hooks amp install` or `cmux hooks setup`.
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
    try {
      fs.accessSync(candidate, fs.constants.X_OK);
      return candidate;
    } catch (_) {}
  }
  return name;
}

function looksLikeAmpExecutable(value: string): boolean {
  return path.basename(value).toLowerCase() === "amp";
}

function looksLikeAmpScript(value: string): boolean {
  const normalized = value.replaceAll("\\", "/");
  const base = path.basename(normalized).toLowerCase();
  return (
    normalized.includes("/@ampcode/") ||
    (base === "cli.js" && normalized.includes("amp"))
  );
}

function looksLikeJavaScriptRuntime(value: string): boolean {
  const base = path.basename(value).toLowerCase();
  return base === "node" || base === "bun" || base === "deno" || base === "tsx" || base === "ts-node";
}

function normalizedLaunchArgv(): string[] {
  const raw = Array.isArray(process.argv) ? process.argv.map((value) => String(value)) : [];
  if (raw.length === 0) return [resolveExecutable("amp")];
  if (looksLikeAmpExecutable(raw[0])) return raw;
  if (raw.length > 1 && (looksLikeAmpScript(raw[1]) || looksLikeJavaScriptRuntime(raw[0]))) {
    return [resolveExecutable("amp"), ...raw.slice(2)];
  }
  return [resolveExecutable("amp")];
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
  // Hook children resolve socket credentials through the scoped keychain or
  // password file; never expose a bearer password/capability in their env.
  delete env.CMUX_SOCKET_PASSWORD;
  delete env.CMUX_SOCKET_CAPABILITY;
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
    case "session-start":
      return "SessionStart";
    case "prompt-submit":
      return "UserPromptSubmit";
    case "stop":
      return "Stop";
    default:
      return subcommand;
  }
}

function sendHook(
  subcommand: string,
  sessionId: string | null,
  cwd: string,
  extra: Record<string, unknown> = {}
): void {
  if (process.env.CMUX_AMP_HOOKS_DISABLED === "1") return;
  if (!process.env.CMUX_SURFACE_ID) return;
  if (!sessionId) return;

  const payload: Record<string, unknown> = {
    session_id: sessionId,
    cwd,
    hook_event_name: eventName(subcommand),
    event: eventName(subcommand),
    ...extra,
  };
  const cmux = process.env.CMUX_AMP_CMUX_BIN || "cmux";
  try {
    const child = spawn(cmux, ["hooks", "amp", subcommand], {
      env: hookEnvironment(cwd),
      stdio: ["pipe", "ignore", "ignore"],
      detached: true,
    });
    child.on("error", () => {});
    child.stdin.on("error", () => {});
    child.stdin.end(JSON.stringify(payload));
    child.unref();
  } catch (_) {}
}

type AmpNativeThreadState = "idle" | "running" | "awaiting-approval" | "error";
type AmpThreadStateSubscription = { unsubscribe(): void };
type AmpThreadStateObservable = {
  get(): Promise<AmpNativeThreadState>;
  subscribe(
    onNext: (state: AmpNativeThreadState) => void
  ): AmpThreadStateSubscription;
};
type AmpThreadContext = {
  thread?: {
    id?: string;
    state?: AmpThreadStateObservable;
  };
};

function threadIdFrom(event: { thread?: { id?: string } } | undefined, ctx?: AmpThreadContext): string | null {
  return firstString(event?.thread?.id, ctx?.thread?.id);
}

// ─── Live status reporting ────────────────────────────────────────────────
// Fires `cmux set-status` / `cmux clear-status` / `cmux log` so the tab
// status bar reflects what Amp is doing (idle, thinking, running cmd,
// reading file X, etc.). All calls are fire-and-forget; failures never
// disturb the agent.

const STATUS_KEY = "amp";
const LOG_SOURCE = "amp";

// Short verbs shown in the cmux status bar for each Amp tool.
function toolLabel(tool: string): string {
  switch (tool) {
    case "Read":
      return "reading";
    case "edit_file":
    case "create_file":
      return "editing";
    case "Bash":
      return "running";
    case "Grep":
    case "finder":
    case "glob":
      return "searching";
    case "Task":
      return "subagent";
    case "oracle":
      return "consulting oracle";
    case "web_search":
    case "read_web_page":
      return "browsing";
    case "mermaid":
      return "diagramming";
    case "handoff":
      return "handing off";
    case "skill":
      return "loading skill";
    case "todo_write":
    case "todo_read":
      return "planning";
    default:
      return tool;
  }
}

// SF Symbol names rendered inside the cmux status badge.
function toolIcon(tool: string): string {
  switch (tool) {
    case "Read":
      return "eye";
    case "edit_file":
    case "create_file":
      return "pencil";
    case "Bash":
      return "terminal";
    case "Grep":
    case "finder":
    case "glob":
      return "magnifyingglass";
    case "Task":
      return "person.2";
    case "oracle":
      return "sparkles";
    case "web_search":
    case "read_web_page":
      return "globe";
    case "todo_write":
    case "todo_read":
      return "checklist";
    default:
      return "hammer";
  }
}

const COLOR = {
  idle: "#adb5bd",
  thinking: "#ffffff",
  active: "#ffd700",
  done: "#50fa7b",
  error: "#ff5555",
  interrupted: "#ffb86c",
} as const;

function truncate(s: string, max: number): string {
  return s.length > max ? s.slice(0, max - 1) + "…" : s;
}

function basename(p: string): string {
  const m = p.match(/[^/]+$/);
  return m ? m[0] : p;
}

// Pin every cmux call to the workspace this plugin process was launched in.
// cmux sets CMUX_WORKSPACE_ID in every pane env, so this is stable across
// async callbacks. Without --workspace, cmux defaults to whichever pane is
// globally focused at the moment of the call, which can be a different
// workspace by the time our async handler runs.
function workspaceArgs(): string[] {
  const ws = process.env.CMUX_WORKSPACE_ID;
  return ws ? ["--workspace", ws] : [];
}

// Minimal environment for cmux status/attention subprocesses. Socket
// credentials are intentionally omitted: the child resolves them through the
// scoped keychain/0600 password file using its explicit socket path, while
// unrelated Amp/cloud credentials never enter the child process environment.
function statusEnvironment(): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = {};
  for (const key of [
    "HOME",
    "PATH",
    "TMPDIR",
    "CMUX_TAG",
    "CMUX_BUNDLE_ID",
    "CMUX_SOCKET",
    "CMUX_SOCKET_PATH",
    "CMUX_CLI_SENTRY_DISABLED",
  ]) {
    const value = process.env[key];
    if (value !== undefined) env[key] = value;
  }
  return env;
}

function runCmux(args: string[]): void {
  if (process.env.CMUX_AMP_HOOKS_DISABLED === "1") return;
  if (!process.env.CMUX_SURFACE_ID) return;
  const cmux = process.env.CMUX_AMP_CMUX_BIN || "cmux";
  try {
    const child = spawn(cmux, args, {
      env: statusEnvironment(),
      stdio: ["ignore", "ignore", "ignore"],
      detached: true,
    });
    child.on("error", () => {});
    child.unref();
  } catch (_) {}
}

const cmuxAcknowledgementDeadlineMilliseconds = 2_000;
const nativeAttentionIdentityDeadlineMilliseconds = 2_000;
const maximumNativeAttentionIdentityBytes = 4_096;

function runCmuxAcknowledged(
  args: string[],
  completion: (succeeded: boolean) => void,
): void {
  if (
    process.env.CMUX_AMP_HOOKS_DISABLED === "1"
    || !process.env.CMUX_SURFACE_ID
  ) {
    completion(false);
    return;
  }
  const cmux = process.env.CMUX_AMP_CMUX_BIN || "cmux";
  let completed = false;
  let deadline: ReturnType<typeof setTimeout> | null = null;
  const finish = (succeeded: boolean): void => {
    if (completed) return;
    completed = true;
    if (deadline) {
      clearTimeout(deadline);
      deadline = null;
    }
    completion(succeeded);
  };
  try {
    const child = spawn(cmux, args, {
      env: statusEnvironment(),
      stdio: ["ignore", "ignore", "ignore"],
    });
    deadline = setTimeout(() => {
      try {
        child.kill("SIGKILL");
      } catch (_) {}
      finish(false);
    }, cmuxAcknowledgementDeadlineMilliseconds);
    deadline.unref?.();
    child.on("error", () => finish(false));
    child.on("close", (status) => finish(status === 0));
  } catch (_) {
    finish(false);
  }
}

type NativeAttentionProcessGeneration = {
  startSeconds: string;
  startMicroseconds: string;
};

function parseNativeAttentionProcessGeneration(
  output: string,
): NativeAttentionProcessGeneration | null {
  try {
    const identity = JSON.parse(output) as {
      pid?: unknown;
      pid_start_seconds?: unknown;
      pid_start_microseconds?: unknown;
    };
    if (
      identity.pid !== process.pid
      || typeof identity.pid_start_seconds !== "number"
      || typeof identity.pid_start_microseconds !== "number"
      || !Number.isSafeInteger(identity.pid_start_seconds)
      || !Number.isSafeInteger(identity.pid_start_microseconds)
      || Number(identity.pid_start_seconds) < 0
      || Number(identity.pid_start_microseconds) < 0
      || Number(identity.pid_start_microseconds) >= 1_000_000
    ) {
      return null;
    }
    return {
      startSeconds: String(identity.pid_start_seconds),
      startMicroseconds: String(identity.pid_start_microseconds),
    };
  } catch (_) {
    return null;
  }
}

function captureNativeAttentionProcessGeneration(): Promise<
  NativeAttentionProcessGeneration | null
> {
  if (process.env.CMUX_AMP_HOOKS_DISABLED === "1") {
    return Promise.resolve(null);
  }
  if (!process.env.CMUX_SURFACE_ID) return Promise.resolve(null);
  const cmux = process.env.CMUX_AMP_CMUX_BIN || "cmux";
  return new Promise((resolve) => {
    let completed = false;
    let output = "";
    let deadline: ReturnType<typeof setTimeout> | null = null;
    const finish = (
      generation: NativeAttentionProcessGeneration | null,
    ): void => {
      if (completed) return;
      completed = true;
      if (deadline) {
        clearTimeout(deadline);
        deadline = null;
      }
      resolve(generation);
    };
    try {
      const child = spawn(cmux, [
        "hooks",
        "amp",
        "__native-attention",
        "identify",
        "--pid",
        String(process.pid),
      ], {
        env: statusEnvironment(),
        stdio: ["ignore", "pipe", "ignore"],
      });
      deadline = setTimeout(() => {
        try {
          child.kill("SIGKILL");
        } catch (_) {}
        finish(null);
      }, nativeAttentionIdentityDeadlineMilliseconds);
      deadline.unref?.();
      child.stdout?.on("data", (chunk) => {
        if (completed) return;
        output += String(chunk);
        if (Buffer.byteLength(output, "utf8")
            > maximumNativeAttentionIdentityBytes) {
          try {
            child.kill("SIGKILL");
          } catch (_) {}
          finish(null);
        }
      });
      child.on("error", () => finish(null));
      child.on("close", (status) => {
        finish(
          status === 0
            ? parseNativeAttentionProcessGeneration(output)
            : null,
        );
      });
    } catch (_) {
      finish(null);
    }
  });
}

let nativeAttentionProcessGenerationCapture: Promise<
  NativeAttentionProcessGeneration | null
> | null = null;
let nativeAttentionProcessGeneration: NativeAttentionProcessGeneration
  | null = null;

function loadNativeAttentionProcessGeneration(): Promise<
  NativeAttentionProcessGeneration | null
> {
  if (nativeAttentionProcessGeneration) {
    return Promise.resolve(nativeAttentionProcessGeneration);
  }
  if (nativeAttentionProcessGenerationCapture) {
    return nativeAttentionProcessGenerationCapture;
  }
  const capture = captureNativeAttentionProcessGeneration();
  nativeAttentionProcessGenerationCapture = capture;
  void capture.then((generation) => {
    if (nativeAttentionProcessGenerationCapture !== capture) return;
    nativeAttentionProcessGenerationCapture = null;
    if (generation) nativeAttentionProcessGeneration = generation;
  });
  return capture;
}

function setStatus(label: string, icon: string, color: string): void {
  runCmux([
    "set-status",
    STATUS_KEY,
    label,
    "--icon",
    icon,
    "--color",
    color,
    ...workspaceArgs(),
  ]);
}

function clearStatus(): void {
  runCmux(["clear-status", STATUS_KEY, ...workspaceArgs()]);
}

function wsLog(message: string, level: string = "info"): void {
  runCmux([
    "log",
    "--level",
    level,
    "--source",
    LOG_SOURCE,
    ...workspaceArgs(),
    "--",
    message,
  ]);
}

// Build a rich status label using Amp Neo helpers when available — e.g.
//   "running: yarn test"
//   "editing: cmux-status.ts"
//   "reading: README.md"
// Falls back to the bare tool name if helpers aren't present (older Amp).
function detailedToolStatus(
  event: ToolCallEvent,
  helpers: unknown,
): { label: string; icon: string } {
  const baseLabel = toolLabel(event.tool);
  const icon = toolIcon(event.tool);
  const h = helpers as
    | {
        shellCommandFromToolCall?: (e: ToolCallEvent) => { command: string } | null;
        filesModifiedByToolCall?: (e: ToolCallEvent) => string[] | null;
        filePathFromURI?: (uri: string) => string;
      }
    | undefined;

  try {
    const shell = h?.shellCommandFromToolCall?.(event);
    if (shell && typeof shell.command === "string") {
      const cmd = shell.command.replace(/\s+/g, " ").trim();
      return { label: `${baseLabel}: ${truncate(cmd, 32)}`, icon };
    }
  } catch (_) {}

  try {
    const files = h?.filesModifiedByToolCall?.(event);
    if (files && files.length > 0) {
      const first = files[0];
      const p = h?.filePathFromURI ? h.filePathFromURI(first) : first;
      return { label: `${baseLabel}: ${truncate(basename(p), 24)}`, icon };
    }
  } catch (_) {}

  if (event.tool === "Read") {
    const p = typeof (event.input as { path?: unknown }).path === "string"
      ? (event.input as { path: string }).path
      : null;
    if (p) return { label: `${baseLabel}: ${truncate(basename(p), 24)}`, icon };
  }

  if (event.tool === "Grep" || event.tool === "glob") {
    const input = event.input as { pattern?: unknown; query?: unknown };
    const pattern =
      typeof input.pattern === "string"
        ? input.pattern
        : typeof input.query === "string"
          ? input.query
          : null;
    if (pattern) return { label: `${baseLabel}: ${truncate(pattern, 24)}`, icon };
  }

  return { label: baseLabel, icon };
}

export default function (amp: PluginAPI) {
  const cwdFromEnv = (): string =>
    firstString(process.env.PWD, process.cwd()) || process.cwd();

  // `helpers` is part of the Neo Plugin API; gracefully degrade if absent.
  const helpers = (amp as unknown as { helpers?: unknown }).helpers;

  type PendingTurnEnd = {
    event: AgentEndEvent;
    sessionId: string | null;
    cwd: string;
  };
  type NativeAttentionEpisodeIdentity = {
    scopeId: string;
    observationId: string;
  };
  type AmpStatusPresentation = {
    label: string;
    icon: string;
    color: string;
  };
  type AmpActiveToolStatus = AmpStatusPresentation & {
    toolUseID: string;
    sequence: number;
  };
  type AmpTurnState = {
    sessionId: string;
    turnId: string;
    activeTools: Map<string, AmpActiveToolStatus>;
    activeToolOverflowed: boolean;
    latestActiveTool: AmpActiveToolStatus | null;
    pendingEnd: PendingTurnEnd | null;
    retired: boolean;
    nativeStateObservable: AmpThreadStateObservable | null;
    nativeStateSubscription: AmpThreadStateSubscription | null;
    nativeStateSnapshotDeadline: ReturnType<typeof setTimeout> | null;
    nativeStateSnapshotCancel: (() => void) | null;
    nativeStateObservationEpoch: number;
    nativeThreadState: AmpNativeThreadState | null;
    nativeAttentionDesiredEpisode: NativeAttentionEpisodeIdentity | null;
    nativeAttentionConfirmedEpisode: NativeAttentionEpisodeIdentity | null;
    nativeAttentionUnconfirmedBeginEpisode: NativeAttentionEpisodeIdentity | null;
    nativeAttentionInFlight: boolean;
    nativeAttentionInFlightAction: "begin" | "end" | null;
    nativeAttentionInFlightEpisode: NativeAttentionEpisodeIdentity | null;
    nativeAttentionRetryCount: number;
    nativeAttentionIdentityRetryCount: number;
    nativeAttentionOwnsSharedStatus: boolean;
  };
  type AmpTurnStateOverflowTombstone = {
    turnId: string;
    provisionalEndPublished: boolean;
  };

  // Amp plugin processes are long-lived and may serve multiple threads
  // concurrently. Tool liveness and provisional completion therefore belong
  // to a thread/turn, never to one process-global counter.
  const turnStates = new Map<string, AmpTurnState>();
  // Evicted turns remain conservative even after their exact observer is
  // released. The bounded map prevents unbounded retention; once its bound is
  // exhausted, the process-wide unknown latch keeps all untracked turns from
  // being recreated until an authoritative process cleanup.
  const turnStateOverflowTombstones = new Map<
    string,
    AmpTurnStateOverflowTombstone
  >();
  let turnStateOverflowedUnknown = false;
  let turnSequence = 0;
  let activeToolStatusSequence = 0;
  let nativeAttentionEpisodeSequence = 0;
  let nativeAttentionStatusOwnerCount = 0;
  let inactiveStatus: AmpStatusPresentation | null = null;

  const makeNativeAttentionEpisode = (): NativeAttentionEpisodeIdentity => {
    const sequence = ++nativeAttentionEpisodeSequence;
    return {
      scopeId: `amp-scope-${process.pid}-${sequence}`,
      observationId: `amp-approval-${process.pid}-${sequence}`,
    };
  };

  const makeTurnState = (
    event: { id?: unknown },
    threadId: string,
    forcedTurnId: string | null = null,
  ): AmpTurnState => {
    const sequence = ++turnSequence;
    return {
      sessionId: threadId,
      turnId:
        forcedTurnId
        || firstString(event.id)
        || `${process.pid}:${threadId}:${Date.now()}:${sequence}`,
      activeTools: new Map(),
      activeToolOverflowed: false,
      latestActiveTool: null,
      pendingEnd: null,
      retired: false,
      nativeStateObservable: null,
      nativeStateSubscription: null,
      nativeStateSnapshotDeadline: null,
      nativeStateSnapshotCancel: null,
      nativeStateObservationEpoch: 0,
      nativeThreadState: null,
      nativeAttentionDesiredEpisode: null,
      nativeAttentionConfirmedEpisode: null,
      nativeAttentionUnconfirmedBeginEpisode: null,
      nativeAttentionInFlight: false,
      nativeAttentionInFlightAction: null,
      nativeAttentionInFlightEpisode: null,
      nativeAttentionRetryCount: 0,
      nativeAttentionIdentityRetryCount: 0,
      nativeAttentionOwnsSharedStatus: false,
    };
  };

  const maximumImmediateNativeAttentionRetries = 1;
  const maximumNativeAttentionIdentityRetries = 2;
  const nativeStateSnapshotDeadlineMilliseconds = 1_000;
  const maximumRetainedActiveToolsPerTurn = 128;
  const maximumRetainedTurnStateCount = 128;
  const maximumTurnStateOverflowTombstones = 128;

  const markTurnStateOverflow = (
    threadId: string,
    state: AmpTurnState,
  ): void => {
    if (turnStateOverflowTombstones.has(threadId)) return;
    if (
      turnStateOverflowTombstones.size
        >= maximumTurnStateOverflowTombstones
    ) {
      turnStateOverflowedUnknown = true;
      return;
    }
    turnStateOverflowTombstones.set(threadId, {
      turnId: state.turnId,
      provisionalEndPublished: false,
    });
  };

  const clearTurnStateOverflow = (threadId?: string): void => {
    if (threadId) {
      turnStateOverflowTombstones.delete(threadId);
      return;
    }
    turnStateOverflowTombstones.clear();
    turnStateOverflowedUnknown = false;
  };

  const hasTurnStateOverflow = (threadId: string): boolean =>
    turnStateOverflowedUnknown
      || turnStateOverflowTombstones.has(threadId);

  const refreshNativeAttentionStatusOwnership = (
    state: AmpTurnState,
  ): void => {
    const shouldOwn = !state.retired
      && (state.nativeThreadState === "awaiting-approval"
      || state.nativeAttentionDesiredEpisode !== null
      || state.nativeAttentionConfirmedEpisode !== null
      || state.nativeAttentionUnconfirmedBeginEpisode !== null
      || state.nativeAttentionInFlight);
    if (shouldOwn === state.nativeAttentionOwnsSharedStatus) return;
    state.nativeAttentionOwnsSharedStatus = shouldOwn;
    nativeAttentionStatusOwnerCount += shouldOwn ? 1 : -1;
  };

  const publishAggregateStatus = (): void => {
    // Feed owns the localized Needs input presentation. Do not let an event
    // from another thread overwrite it until every possibly visible native
    // approval has been acknowledged as concluded.
    if (nativeAttentionStatusOwnerCount > 0) return;

    let activeTool: AmpActiveToolStatus | null = null;
    for (const state of turnStates.values()) {
      const candidate = state.latestActiveTool;
      if (candidate && (!activeTool || candidate.sequence > activeTool.sequence)) {
        activeTool = candidate;
      }
    }
    if (activeTool) {
      setStatus(activeTool.label, activeTool.icon, activeTool.color);
      return;
    }
    if (
      turnStates.size > 0
      || turnStateOverflowedUnknown
      || turnStateOverflowTombstones.size > 0
    ) {
      setStatus("thinking", "brain", COLOR.thinking);
      return;
    }
    if (inactiveStatus) {
      setStatus(
        inactiveStatus.label,
        inactiveStatus.icon,
        inactiveStatus.color,
      );
    }
  };

  const nativeAttentionArguments = (
    action: "begin" | "end",
    sessionId: string,
    episode: NativeAttentionEpisodeIdentity,
    processGeneration: NativeAttentionProcessGeneration,
  ): string[] | null => {
    const args = [
      "hooks",
      "amp",
      "__native-attention",
      action,
      "--pid",
      String(process.pid),
      "--pid-start-seconds",
      processGeneration.startSeconds,
      "--pid-start-microseconds",
      processGeneration.startMicroseconds,
      "--scope-id",
      episode.scopeId,
      "--observation-id",
      episode.observationId,
      "--session-id",
      sessionId,
    ];
    if (action === "begin") {
      const workspaceId = firstString(process.env.CMUX_WORKSPACE_ID);
      const surfaceId = firstString(process.env.CMUX_SURFACE_ID);
      if (!workspaceId || !surfaceId) return null;
      args.push(
        "--workspace-id",
        workspaceId,
        "--surface-id",
        surfaceId,
      );
    }
    return args;
  };

  const concludeNativeAttentionEpisode = (
    sessionId: string,
    episode: NativeAttentionEpisodeIdentity,
    knownProcessGeneration: NativeAttentionProcessGeneration | null = null,
  ): void => {
    const conclude = (
      processGeneration: NativeAttentionProcessGeneration | null,
    ): void => {
      if (!processGeneration) return;
      const args = nativeAttentionArguments(
        "end",
        sessionId,
        episode,
        processGeneration,
      );
      if (args) runCmuxAcknowledged(args, () => {});
    };
    if (knownProcessGeneration) {
      conclude(knownProcessGeneration);
    } else {
      void loadNativeAttentionProcessGeneration().then(conclude);
    }
  };

  const synchronizeNativeAttention = (state: AmpTurnState): void => {
    if (state.retired || state.nativeAttentionInFlight) return;
    const desiredEpisode = state.nativeAttentionDesiredEpisode;
    const confirmedEpisode = state.nativeAttentionConfirmedEpisode;
    const unconfirmedBeginEpisode =
      state.nativeAttentionUnconfirmedBeginEpisode;
    let transition: {
      action: "begin" | "end";
      episode: NativeAttentionEpisodeIdentity;
      unconfirmedCleanup: boolean;
    } | null = null;
    if (confirmedEpisode && confirmedEpisode !== desiredEpisode) {
      transition = {
        action: "end",
        episode: confirmedEpisode,
        unconfirmedCleanup: false,
      };
    } else if (
      unconfirmedBeginEpisode
      && unconfirmedBeginEpisode !== desiredEpisode
    ) {
      transition = {
        action: "end",
        episode: unconfirmedBeginEpisode,
        unconfirmedCleanup: true,
      };
    } else if (desiredEpisode && confirmedEpisode !== desiredEpisode) {
      transition = {
        action: "begin",
        episode: desiredEpisode,
        unconfirmedCleanup: false,
      };
    }
    if (!transition) return;
    const attemptedVisibility = transition.action === "begin";
    const attemptedUnconfirmedCleanup = transition.unconfirmedCleanup;
    const attemptedEpisode = transition.episode;
    const transitionIsStillNeeded = (): boolean => {
      if (state.retired) return false;
      if (attemptedVisibility) {
        return state.nativeAttentionConfirmedEpisode === null
          && state.nativeAttentionDesiredEpisode === attemptedEpisode;
      }
      if (attemptedUnconfirmedCleanup) {
        return state.nativeAttentionUnconfirmedBeginEpisode
            === attemptedEpisode
          && state.nativeAttentionDesiredEpisode !== attemptedEpisode;
      }
      return state.nativeAttentionConfirmedEpisode === attemptedEpisode;
    };
    state.nativeAttentionInFlight = true;
    state.nativeAttentionInFlightAction = transition.action;
    state.nativeAttentionInFlightEpisode = attemptedEpisode;
    refreshNativeAttentionStatusOwnership(state);
    void loadNativeAttentionProcessGeneration().then((processGeneration) => {
      if (!processGeneration) {
        state.nativeAttentionInFlight = false;
        state.nativeAttentionInFlightAction = null;
        state.nativeAttentionInFlightEpisode = null;
        if (state.retired) return;
        if (
          transitionIsStillNeeded()
          && state.nativeAttentionIdentityRetryCount
            < maximumNativeAttentionIdentityRetries
        ) {
          state.nativeAttentionIdentityRetryCount += 1;
          queueMicrotask(() => {
            if (state.retired || turnStates.get(state.sessionId) !== state) return;
            if (transitionIsStillNeeded()) {
              synchronizeNativeAttention(state);
            }
          });
        }
        if (!transitionIsStillNeeded()) {
          state.nativeAttentionIdentityRetryCount = 0;
          synchronizeNativeAttention(state);
        }
        refreshNativeAttentionStatusOwnership(state);
        publishAggregateStatus();
        return;
      }
      state.nativeAttentionIdentityRetryCount = 0;
      if (state.retired) {
        state.nativeAttentionInFlight = false;
        state.nativeAttentionInFlightAction = null;
        state.nativeAttentionInFlightEpisode = null;
        return;
      }
      if (!transitionIsStillNeeded()) {
        state.nativeAttentionInFlight = false;
        state.nativeAttentionInFlightAction = null;
        state.nativeAttentionInFlightEpisode = null;
        synchronizeNativeAttention(state);
        refreshNativeAttentionStatusOwnership(state);
        publishAggregateStatus();
        return;
      }
      const action = attemptedVisibility ? "begin" : "end";
      const args = nativeAttentionArguments(
        action,
        state.sessionId,
        attemptedEpisode,
        processGeneration,
      );
      if (!args) {
        state.nativeAttentionInFlight = false;
        state.nativeAttentionInFlightAction = null;
        state.nativeAttentionInFlightEpisode = null;
        refreshNativeAttentionStatusOwnership(state);
        publishAggregateStatus();
        return;
      }
      runCmuxAcknowledged(args, (succeeded) => {
        state.nativeAttentionInFlight = false;
        state.nativeAttentionInFlightAction = null;
        state.nativeAttentionInFlightEpisode = null;
        if (state.retired) {
          if (attemptedVisibility) {
            // The begin may have committed before a lost acknowledgement. A
            // post-retirement completion may only issue idempotent cleanup.
            concludeNativeAttentionEpisode(
              state.sessionId,
              attemptedEpisode,
              processGeneration,
            );
          }
          return;
        }
        if (succeeded) {
          if (attemptedVisibility) {
            state.nativeAttentionConfirmedEpisode = attemptedEpisode;
            if (
              state.nativeAttentionUnconfirmedBeginEpisode
                === attemptedEpisode
            ) {
              state.nativeAttentionUnconfirmedBeginEpisode = null;
            }
          } else {
            if (state.nativeAttentionConfirmedEpisode === attemptedEpisode) {
              state.nativeAttentionConfirmedEpisode = null;
            }
            if (
              state.nativeAttentionUnconfirmedBeginEpisode
                === attemptedEpisode
            ) {
              state.nativeAttentionUnconfirmedBeginEpisode = null;
            }
          }
          state.nativeAttentionRetryCount = 0;
        } else {
          if (attemptedVisibility) {
            // A child can apply the begin before its response is lost or the
            // deadline kills it. Preserve that uncertainty until the desired
            // state advances, then send an idempotent end for this episode.
            state.nativeAttentionUnconfirmedBeginEpisode = attemptedEpisode;
          }
          if (transitionIsStillNeeded()) {
            if (
              state.nativeAttentionRetryCount
                < maximumImmediateNativeAttentionRetries
            ) {
              state.nativeAttentionRetryCount += 1;
            } else {
              state.nativeAttentionRetryCount = 0;
              if (!attemptedVisibility) {
                if (
                  state.nativeAttentionConfirmedEpisode === attemptedEpisode
                ) {
                  state.nativeAttentionConfirmedEpisode = null;
                }
                if (
                  state.nativeAttentionUnconfirmedBeginEpisode
                    === attemptedEpisode
                ) {
                  state.nativeAttentionUnconfirmedBeginEpisode = null;
                }
              }
              refreshNativeAttentionStatusOwnership(state);
              publishAggregateStatus();
              return;
            }
          } else {
            state.nativeAttentionRetryCount = 0;
          }
        }
        synchronizeNativeAttention(state);
        refreshNativeAttentionStatusOwnership(state);
        publishAggregateStatus();
      });
    });
  };

  const beginNativeAttention = (state: AmpTurnState): void => {
    if (state.retired) return;
    if (!state.nativeAttentionDesiredEpisode) {
      state.nativeAttentionIdentityRetryCount = 0;
      state.nativeAttentionDesiredEpisode = makeNativeAttentionEpisode();
    }
    refreshNativeAttentionStatusOwnership(state);
    synchronizeNativeAttention(state);
    publishAggregateStatus();
  };

  const endNativeAttention = (state: AmpTurnState): void => {
    if (state.retired) return;
    state.nativeAttentionIdentityRetryCount = 0;
    state.nativeAttentionDesiredEpisode = null;
    refreshNativeAttentionStatusOwnership(state);
    synchronizeNativeAttention(state);
    publishAggregateStatus();
  };

  const clearNativeStateObservation = (state: AmpTurnState): void => {
    state.nativeStateObservationEpoch += 1;
    if (state.nativeStateSnapshotDeadline) {
      clearTimeout(state.nativeStateSnapshotDeadline);
      state.nativeStateSnapshotDeadline = null;
    }
    state.nativeStateSnapshotCancel?.();
    state.nativeStateSnapshotCancel = null;
    state.nativeStateSubscription?.unsubscribe();
    state.nativeStateSubscription = null;
    state.nativeStateObservable = null;
    state.nativeThreadState = null;
  };

  const discardTurnState = (
    threadId: string,
    state: AmpTurnState | undefined,
  ): void => {
    if (!state || state.retired) return;
    const cleanupEpisodes = new Map<
      string,
      NativeAttentionEpisodeIdentity
    >();
    for (const episode of [
      state.nativeAttentionDesiredEpisode,
      state.nativeAttentionConfirmedEpisode,
      state.nativeAttentionUnconfirmedBeginEpisode,
      state.nativeAttentionInFlightAction === "begin"
        ? state.nativeAttentionInFlightEpisode
        : null,
    ]) {
      if (episode) cleanupEpisodes.set(episode.observationId, episode);
    }
    // Retirement is a one-way boundary: remove ownership before any async
    // cleanup can finish and attempt to observe this state again.
    state.retired = true;
    if (turnStates.get(threadId) === state) {
      turnStates.delete(threadId);
    }
    clearNativeStateObservation(state);
    refreshNativeAttentionStatusOwnership(state);
    state.nativeAttentionDesiredEpisode = null;
    state.nativeAttentionConfirmedEpisode = null;
    state.nativeAttentionUnconfirmedBeginEpisode = null;
    state.nativeAttentionIdentityRetryCount = 0;
    for (const episode of cleanupEpisodes.values()) {
      concludeNativeAttentionEpisode(state.sessionId, episode);
    }
  };

  const touchTurnState = (
    threadId: string,
    state: AmpTurnState,
  ): void => {
    if (state.retired || turnStates.get(threadId) !== state) return;
    turnStates.delete(threadId);
    turnStates.set(threadId, state);
  };

  const evictTurnState = (
    threadId: string,
    state: AmpTurnState,
  ): void => {
    markTurnStateOverflow(threadId, state);
    discardTurnState(threadId, state);
  };

  const retainTurnState = (
    threadId: string,
    state: AmpTurnState,
  ): void => {
    if (state.retired) return;
    const existing = turnStates.get(threadId);
    if (existing && existing !== state) {
      discardTurnState(threadId, existing);
    }
    turnStates.delete(threadId);
    turnStates.set(threadId, state);
    while (turnStates.size > maximumRetainedTurnStateCount) {
      const oldest = turnStates.entries().next().value;
      if (!oldest) break;
      evictTurnState(oldest[0], oldest[1]);
    }
  };

  const retainNativeStateObservation = (
    threadId: string,
    state: AmpTurnState,
    observationEpoch: number,
  ): void => {
    if (
      state.retired
      || turnStates.get(threadId) !== state
      || state.nativeStateObservationEpoch !== observationEpoch
    ) {
      return;
    }
    touchTurnState(threadId, state);
  };

  const publishSettledTurn = (
    threadId: string,
    state: AmpTurnState,
    pendingEnd: PendingTurnEnd,
  ): void => {
    discardTurnState(threadId, state);
    const activeSiblingTurnCount = turnStates.size;
    if (activeSiblingTurnCount === 0) {
      switch (pendingEnd.event.status) {
        case "done":
          inactiveStatus = {
            label: "done",
            icon: "checkmark.circle",
            color: COLOR.done,
          };
          wsLog("turn complete", "success");
          break;
        case "error":
          inactiveStatus = {
            label: "error",
            icon: "xmark.circle",
            color: COLOR.error,
          };
          wsLog("turn errored", "error");
          break;
        case "cancelled":
          inactiveStatus = {
            label: "interrupted",
            icon: "pause.circle",
            color: COLOR.interrupted,
          };
          wsLog("turn interrupted", "warning");
          break;
        default:
          inactiveStatus = {
            label: String(pendingEnd.event.status ?? "done"),
            icon: "questionmark.circle",
            color: COLOR.interrupted,
          };
          wsLog(
            `turn ended with unexpected status: ${pendingEnd.event.status}`,
            "warning",
          );
          break;
      }
    }
    publishAggregateStatus();
    sendHook("stop", pendingEnd.sessionId, pendingEnd.cwd, {
      turn_id: state.turnId,
      cmux_turn_boundary: "settled",
      cmux_active_background_work_count: 0,
      cmux_active_sibling_turn_count: activeSiblingTurnCount,
    });
  };

  const tryPublishSettledTurn = (
    threadId: string,
    state: AmpTurnState,
  ): void => {
    if (state.retired) return;
    const pendingEnd = state.pendingEnd;
    if (
      !pendingEnd
      || state.activeTools.size > 0
      || state.activeToolOverflowed
    ) return;
    if (
      state.nativeStateObservable
      && state.nativeThreadState !== "idle"
      && state.nativeThreadState !== "error"
    ) {
      return;
    }
    state.pendingEnd = null;
    publishSettledTurn(threadId, state, pendingEnd);
  };

  const observeNativeThreadState = async (
    threadId: string,
    state: AmpTurnState,
    ctx: AmpThreadContext,
  ): Promise<void> => {
    if (state.retired || turnStates.get(threadId) !== state) return;
    const observable = ctx.thread?.state;
    if (
      !observable
      || typeof observable.get !== "function"
      || typeof observable.subscribe !== "function"
    ) {
      // Older Amp runtimes do not expose PluginThread.state. Their fallback
      // boundary is the structured active-tool set becoming empty.
      tryPublishSettledTurn(threadId, state);
      return;
    }

    if (
      state.nativeStateObservable === observable
      && state.nativeStateSubscription
    ) {
      retainNativeStateObservation(
        threadId,
        state,
        state.nativeStateObservationEpoch,
      );
      tryPublishSettledTurn(threadId, state);
      return;
    }

    clearNativeStateObservation(state);
    const observationEpoch = state.nativeStateObservationEpoch;
    const fallbackAfterNativeStateFailure = (): void => {
      if (
        state.retired
        || turnStates.get(threadId) !== state
        || state.nativeStateObservationEpoch !== observationEpoch
      ) {
        return;
      }
      // A present-but-failing native API is not authoritative. Drop the
      // failed observer and use the bounded structured-tool fallback instead
      // of retaining a pending end forever.
      clearNativeStateObservation(state);
      tryPublishSettledTurn(threadId, state);
      if (turnStates.get(threadId) === state) publishAggregateStatus();
    };
    const applyNativeState = (nativeState: AmpNativeThreadState): void => {
      if (
        state.retired
        || turnStates.get(threadId) !== state
        || state.nativeStateObservationEpoch !== observationEpoch
      ) {
        return;
      }
      state.nativeThreadState = nativeState;
      if (nativeState === "awaiting-approval") {
        beginNativeAttention(state);
      } else {
        endNativeAttention(state);
      }
      if (nativeState === "idle" || nativeState === "error") {
        // Amp can terminate an errored/cancelled turn without emitting a final
        // tool.result. An authoritative terminal native state closes retained
        // and overflowed tool lifetimes together.
        state.activeTools.clear();
        state.activeToolOverflowed = false;
        state.latestActiveTool = null;
      }
      tryPublishSettledTurn(threadId, state);
      if (turnStates.get(threadId) === state) {
        publishAggregateStatus();
      }
    };

    state.nativeStateObservable = observable;
    let didReceiveSubscriptionState = false;
    let resolveSubscriptionState: (() => void) | null = null;
    const subscriptionState = new Promise<void>((resolve) => {
      resolveSubscriptionState = () => resolve();
    });
    try {
      const subscription = observable.subscribe((nativeState) => {
        if (
          state.retired
          || turnStates.get(threadId) !== state
          || state.nativeStateObservationEpoch !== observationEpoch
        ) {
          return;
        }
        didReceiveSubscriptionState = true;
        resolveSubscriptionState?.();
        resolveSubscriptionState = null;
        applyNativeState(nativeState);
        retainNativeStateObservation(
          threadId,
          state,
          observationEpoch,
        );
      });
      if (
        !state.retired
        && turnStates.get(threadId) === state
        && state.nativeStateObservationEpoch === observationEpoch
      ) {
        state.nativeStateSubscription = subscription;
      } else {
        subscription.unsubscribe();
      }
    } catch (_) {
      state.nativeStateSubscription = null;
      fallbackAfterNativeStateFailure();
      return;
    }
    if (state.retired || turnStates.get(threadId) !== state) return;
    retainNativeStateObservation(threadId, state, observationEpoch);

    let acceptsInitialSnapshot = true;
    let nativeSnapshotFailed = false;
    const snapshotState = Promise.resolve()
      .then(() => observable.get())
      .then((initialState) => {
        if (
          acceptsInitialSnapshot
          && !didReceiveSubscriptionState
          && state.nativeThreadState === null
        ) {
          applyNativeState(initialState);
        }
      })
      .catch(() => {
        nativeSnapshotFailed = !didReceiveSubscriptionState;
      });
    let cancelSnapshotWait: (() => void) | null = null;
    const snapshotCancelled = new Promise<void>((resolve) => {
      cancelSnapshotWait = () => resolve();
      state.nativeStateSnapshotCancel = cancelSnapshotWait;
    });
    let snapshotDeadline: ReturnType<typeof setTimeout> | null = null;
    const snapshotTimedOut = new Promise<void>((resolve) => {
      snapshotDeadline = setTimeout(
        resolve,
        nativeStateSnapshotDeadlineMilliseconds,
      );
      state.nativeStateSnapshotDeadline = snapshotDeadline;
    });
    try {
      await Promise.race([
        snapshotState,
        subscriptionState,
        snapshotTimedOut,
        snapshotCancelled,
      ]);
      if (
        nativeSnapshotFailed
        && !didReceiveSubscriptionState
        && state.nativeThreadState === null
      ) {
        fallbackAfterNativeStateFailure();
      } else if (!state.retired && turnStates.get(threadId) === state) {
        tryPublishSettledTurn(threadId, state);
      }
    } finally {
      acceptsInitialSnapshot = false;
      if (snapshotDeadline) clearTimeout(snapshotDeadline);
      if (state.nativeStateSnapshotDeadline === snapshotDeadline) {
        state.nativeStateSnapshotDeadline = null;
      }
      if (state.nativeStateSnapshotCancel === cancelSnapshotWait) {
        state.nativeStateSnapshotCancel = null;
      }
    }
  };

  // Best-effort cleanup so the badge doesn't get stuck after the agent exits.
  // We intentionally only hook the `exit` event and do NOT register custom
  // SIGINT/SIGTERM listeners:
  //   - Registering a SIGINT/SIGTERM listener would disable Node's default
  //     exit-on-signal behavior, so we'd then be responsible for calling
  //     process.exit() ourselves.
  //   - We don't know whether the Amp plugin host runs us as a dedicated child
  //     process or shares its process with other plugins; calling
  //     process.exit() in the shared-process case would short-circuit the
  //     host's graceful shutdown.
  // Letting Node's default signal handler run is correct in both deployments:
  //   - dedicated child: signal -> default handler -> process exits -> `exit`
  //     event fires -> clearStatus() runs.
  //   - shared host: host process orchestrates shutdown, our `exit` listener
  //     still runs as part of normal teardown.
  process.on("exit", () => {
    try {
      clearStatus();
      clearTurnStateOverflow();
    } catch (_) {}
  });

  amp.on("session.start", async (event: SessionStartEvent, ctx) => {
    const sessionId = threadIdFrom(event, ctx);
    if (sessionId) {
      // A new session boundary is the only event that can prove an evicted
      // turn from this thread no longer owns unresolved work.
      clearTurnStateOverflow(sessionId);
      discardTurnState(sessionId, turnStates.get(sessionId));
    }
    inactiveStatus = {
      label: "idle",
      icon: "circle",
      color: COLOR.idle,
    };
    publishAggregateStatus();
    if (!sessionId) return;
    sendHook("session-start", sessionId, cwdFromEnv());
  });

  amp.on("agent.start", async (event: AgentStartEvent, ctx) => {
    const sessionId = threadIdFrom(event, ctx);
    if (!sessionId) return;
    if (hasTurnStateOverflow(sessionId)) {
      // Do not let a later start manufacture a clean state for work whose
      // exact observer was evicted. Session/process cleanup must clear it.
      publishAggregateStatus();
      return;
    }
    discardTurnState(sessionId, turnStates.get(sessionId));
    const state = makeTurnState(event, sessionId);
    retainTurnState(sessionId, state);
    publishAggregateStatus();
    wsLog("prompt received");
    sendHook("prompt-submit", sessionId, cwdFromEnv(), {
      turn_id: state.turnId,
    });
    await observeNativeThreadState(sessionId, state, ctx);
  });

  amp.on("tool.call", async (event: ToolCallEvent, ctx) => {
    const sessionId = threadIdFrom(event, ctx);
    const state = sessionId ? turnStates.get(sessionId) : undefined;
    const { label, icon } = detailedToolStatus(event, helpers);
    if (state) {
      const activeTool = {
        toolUseID: event.toolUseID,
        label,
        icon,
        color: COLOR.active,
        sequence: ++activeToolStatusSequence,
      };
      if (
        state.activeTools.has(event.toolUseID)
        || state.activeTools.size < maximumRetainedActiveToolsPerTurn
      ) {
        state.activeTools.set(event.toolUseID, activeTool);
      } else {
        // Once an identity is dropped, retained results cannot prove every
        // tool ended. Only a terminal native state can clear this latch.
        state.activeToolOverflowed = true;
      }
      state.latestActiveTool = activeTool;
      retainNativeStateObservation(
        state.sessionId,
        state,
        state.nativeStateObservationEpoch,
      );
      publishAggregateStatus();
    }
    return { action: "allow" as const };
  });

  amp.on("tool.result", async (event: ToolResultEvent, ctx) => {
    const sessionId = threadIdFrom(event, ctx);
    const state = sessionId ? turnStates.get(sessionId) : undefined;
    if (state) {
      state.activeTools.delete(event.toolUseID);
      if (state.latestActiveTool?.toolUseID === event.toolUseID) {
        state.latestActiveTool = null;
        for (const candidate of state.activeTools.values()) {
          if (
            !state.latestActiveTool
            || candidate.sequence > state.latestActiveTool.sequence
          ) {
            state.latestActiveTool = candidate;
          }
        }
      }
      retainNativeStateObservation(
        state.sessionId,
        state,
        state.nativeStateObservationEpoch,
      );
    }
    if (event.status === "error") {
      wsLog(`${event.tool} failed`, "error");
    }
    if (sessionId && state?.pendingEnd) {
      tryPublishSettledTurn(sessionId, state);
    }
    if (state && turnStates.get(state.sessionId) === state) {
      publishAggregateStatus();
    }
  });

  amp.on("agent.end", async (event: AgentEndEvent, ctx) => {
    const sessionId = threadIdFrom(event, ctx);
    const cwd = cwdFromEnv();
    if (!sessionId) return;
    const currentState = turnStates.get(sessionId);
    // Current Amp releases require the same message id on agent.start/end.
    // Older or partially upgraded runtimes may omit it; in that case the
    // current per-thread turn is the only safe identity to reuse.
    const incomingTurnId = firstString(event.id)
      || currentState?.turnId
      || `${process.pid}:${sessionId}:${Date.now()}:${turnSequence + 1}`;
    if (!currentState && hasTurnStateOverflow(sessionId)) {
      const tombstone = turnStateOverflowTombstones.get(sessionId);
      if (tombstone && !tombstone.provisionalEndPublished) {
        tombstone.provisionalEndPublished = true;
        sendHook("stop", sessionId, cwd, {
          turn_id: tombstone.turnId,
          cmux_turn_boundary: "turn_end",
          cmux_active_background_work_count: 1,
        });
      }
      // A bounded eviction dropped exact work ownership. Never recreate an
      // empty state from this late end; only session/process cleanup can
      // retire the overflow tombstone.
      publishAggregateStatus();
      return;
    }
    if (currentState && currentState.turnId !== incomingTurnId) {
      // A late end from a superseded turn must never consume the newer turn's
      // tool set. Publish it as settled evidence; the shared reconciler rejects
      // it against the current turn id.
      sendHook("stop", sessionId, cwd, {
        turn_id: incomingTurnId,
        cmux_turn_boundary: "settled",
        cmux_active_background_work_count: 0,
      });
      return;
    }
    const state = currentState
      ?? makeTurnState(event, sessionId, incomingTurnId);
    retainTurnState(sessionId, state);
    const pendingEnd = { event, sessionId, cwd };
    state.pendingEnd = pendingEnd;
    // agent.end is always provisional. Only PluginThread.state reaching a
    // terminal boundary, plus an empty structured work set, may emit settled.
    sendHook("stop", sessionId, cwd, {
      turn_id: state.turnId,
      cmux_turn_boundary: "turn_end",
      cmux_active_background_work_count: state.activeTools.size
        + (state.activeToolOverflowed ? 1 : 0),
    });
    await observeNativeThreadState(sessionId, state, ctx);
  });
}
"""#

    private func ampExtensionURL(for def: AgentHookDef) -> URL {
        URL(fileURLWithPath: def.resolvedConfigDir(), isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent(Self.ampExtensionFilename, isDirectory: false)
    }

    @discardableResult
    private func withAmpExtensionMutationLock<T>(
        at extensionURL: URL,
        createParentDirectory: Bool,
        acquireNonBlocking: Bool = false,
        fileManager: FileManager = .default,
        _ operation: () throws -> T
    ) throws -> T? {
        let directoryURL = extensionURL.deletingLastPathComponent()
        if createParentDirectory {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        }
        let lockURL = directoryURL.appendingPathComponent(
            ".cmux-session.lock",
            isDirectory: false
        )
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: lockURL.path]
            )
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: lockURL.path]
            )
        }
        let lockOperation = LOCK_EX | (acquireNonBlocking ? LOCK_NB : 0)
        guard flock(descriptor, lockOperation) == 0 else {
            if acquireNonBlocking,
               errno == EWOULDBLOCK || errno == EAGAIN {
                return nil
            }
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: lockURL.path]
            )
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    func refreshManagedAmpExtensionIfNeeded(_ def: AgentHookDef) {
        let extensionURL = ampExtensionURL(for: def)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: extensionURL.path) else { return }
        do {
            try withAmpExtensionMutationLock(
                at: extensionURL,
                createParentDirectory: false,
                acquireNonBlocking: true,
                fileManager: fileManager
            ) {
                guard fileManager.fileExists(atPath: extensionURL.path) else {
                    return
                }
                let existing = try String(
                    contentsOf: extensionURL,
                    encoding: .utf8
                )
                guard existing.contains(Self.ampExtensionMarker),
                      existing != Self.ampExtensionSource else {
                    return
                }
                // All cmux plugin mutations share this lock. Revalidation keeps
                // a concurrent user replacement or uninstall authoritative.
                guard try String(
                    contentsOf: extensionURL,
                    encoding: .utf8
                ) == existing else {
                    return
                }
                try Self.ampExtensionSource.write(
                    to: extensionURL,
                    atomically: true,
                    encoding: .utf8
                )
            }
        } catch {
            // Hook delivery must continue when a managed plugin cannot refresh.
        }
    }

    func installAmpExtensionHooks(_ def: AgentHookDef) throws {
        let extensionURL = ampExtensionURL(for: def)
        let skipConfirm = ProcessInfo.processInfo.arguments.contains("--yes")
            || ProcessInfo.processInfo.arguments.contains("-y")
        let existing = (try? String(
            contentsOf: extensionURL,
            encoding: .utf8
        )) ?? ""
        if existing == Self.ampExtensionSource {
            print("Amp hooks already up to date at \(extensionURL.path)")
            return
        }
        if !existing.isEmpty,
           !existing.contains(Self.ampExtensionMarker) {
            throw CLIError(message: "\(extensionURL.path) exists and is not a cmux plugin; leaving it alone")
        }
        if !skipConfirm {
            Self.printInstallPreview(
                path: extensionURL.path,
                oldContent: existing,
                newContent: Self.ampExtensionSource,
                fallbackContent: Self.ampExtensionSource
            )
            print("\nProceed? [y/N] ", terminator: "")
            guard readLine()?.lowercased().hasPrefix("y") == true else {
                print("Aborted.")
                return
            }
        }
        let installed = try withAmpExtensionMutationLock(
            at: extensionURL,
            createParentDirectory: true
        ) {
            let current = (try? String(
                contentsOf: extensionURL,
                encoding: .utf8
            )) ?? ""
            guard current == existing else { return false }
            try Self.ampExtensionSource.write(
                to: extensionURL,
                atomically: true,
                encoding: .utf8
            )
            return true
        } ?? false
        if installed {
            print("Amp hooks installed at \(extensionURL.path)")
        }
    }

    func uninstallAmpExtensionHooks(_ def: AgentHookDef) throws {
        let extensionURL = ampExtensionURL(for: def)
        let fm = FileManager.default
        guard fm.fileExists(atPath: extensionURL.path) else {
            print("No Amp cmux plugin found at \(extensionURL.path)")
            return
        }
        let existing = (try? String(
            contentsOf: extensionURL,
            encoding: .utf8
        )) ?? ""
        guard existing.contains(Self.ampExtensionMarker) else {
            print("Refusing to remove \(extensionURL.path): missing cmux marker")
            return
        }
        let removed = try withAmpExtensionMutationLock(
            at: extensionURL,
            createParentDirectory: false,
            fileManager: fm
        ) {
            guard fm.fileExists(atPath: extensionURL.path) else {
                return false
            }
            let current = (try? String(
                contentsOf: extensionURL,
                encoding: .utf8
            )) ?? ""
            guard current == existing else { return false }
            try fm.removeItem(at: extensionURL)
            return true
        } ?? false
        if removed {
            print("Removed Amp cmux plugin from \(extensionURL.path)")
        }
    }
}
