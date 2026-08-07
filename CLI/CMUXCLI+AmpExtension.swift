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

// Sanitized environment for fire-and-forget cmux status subprocesses.
// Strips Amp-provided secrets (`AMP_API_KEY`) so we never propagate them to
// every spawned `cmux set-status` / `cmux log` / `cmux clear-status` child.
// Mirrors the secret-stripping done in `hookEnvironment` without the launch-
// metadata fields, which are only meaningful for lifecycle hook calls.
function statusEnvironment(): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = { ...process.env };
  delete env.AMP_API_KEY;
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
  type AmpTurnState = {
    sessionId: string;
    turnId: string;
    activeToolUseIds: Set<string>;
    pendingEnd: PendingTurnEnd | null;
    nativeStateObservable: AmpThreadStateObservable | null;
    nativeStateSubscription: AmpThreadStateSubscription | null;
    nativeStateObservationLease: ReturnType<typeof setTimeout> | null;
    nativeStateObservationEpoch: number;
    nativeThreadState: AmpNativeThreadState | null;
    nativeAttentionDesiredEpisode: NativeAttentionEpisodeIdentity | null;
    nativeAttentionConfirmedEpisode: NativeAttentionEpisodeIdentity | null;
    nativeAttentionUnconfirmedBeginEpisode: NativeAttentionEpisodeIdentity | null;
    nativeAttentionInFlight: boolean;
    nativeAttentionRetryCount: number;
    nativeAttentionIdentityRetryTimer: ReturnType<typeof setTimeout> | null;
    nativeAttentionIdentityRetryCount: number;
  };

  // Amp plugin processes are long-lived and may serve multiple threads
  // concurrently. Tool liveness and provisional completion therefore belong
  // to a thread/turn, never to one process-global counter.
  const turnStates = new Map<string, AmpTurnState>();
  let turnSequence = 0;
  let nativeAttentionEpisodeSequence = 0;

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
      activeToolUseIds: new Set(),
      pendingEnd: null,
      nativeStateObservable: null,
      nativeStateSubscription: null,
      nativeStateObservationLease: null,
      nativeStateObservationEpoch: 0,
      nativeThreadState: null,
      nativeAttentionDesiredEpisode: null,
      nativeAttentionConfirmedEpisode: null,
      nativeAttentionUnconfirmedBeginEpisode: null,
      nativeAttentionInFlight: false,
      nativeAttentionRetryCount: 0,
      nativeAttentionIdentityRetryTimer: null,
      nativeAttentionIdentityRetryCount: 0,
    };
  };

  const maximumImmediateNativeAttentionRetries = 1;
  const maximumNativeAttentionIdentityRetries = 2;
  const nativeAttentionIdentityRetryDelayMilliseconds = 250;
  const nativeStateSnapshotDeadlineMilliseconds = 1_000;
  const activeNativeStateObservationLeaseMilliseconds = 30 * 60 * 1_000;
  const maximumRetainedTurnStateCount = 128;

  const synchronizeNativeAttention = (state: AmpTurnState): void => {
    if (state.nativeAttentionInFlight) return;
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
    const workspaceId = firstString(process.env.CMUX_WORKSPACE_ID);
    const surfaceId = firstString(process.env.CMUX_SURFACE_ID);
    if (!workspaceId || !surfaceId) return;
    const transitionIsStillNeeded = (): boolean => {
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
    void loadNativeAttentionProcessGeneration().then((processGeneration) => {
      if (!processGeneration) {
        state.nativeAttentionInFlight = false;
        if (
          transitionIsStillNeeded()
          && !state.nativeAttentionIdentityRetryTimer
          && state.nativeAttentionIdentityRetryCount
            < maximumNativeAttentionIdentityRetries
        ) {
          state.nativeAttentionIdentityRetryCount += 1;
          state.nativeAttentionIdentityRetryTimer = setTimeout(() => {
            state.nativeAttentionIdentityRetryTimer = null;
            if (turnStates.get(state.sessionId) !== state) return;
            if (transitionIsStillNeeded()) {
              synchronizeNativeAttention(state);
            }
          }, nativeAttentionIdentityRetryDelayMilliseconds);
          state.nativeAttentionIdentityRetryTimer.unref?.();
        }
        if (!transitionIsStillNeeded()) {
          state.nativeAttentionIdentityRetryCount = 0;
          synchronizeNativeAttention(state);
        }
        return;
      }
      if (state.nativeAttentionIdentityRetryTimer) {
        clearTimeout(state.nativeAttentionIdentityRetryTimer);
        state.nativeAttentionIdentityRetryTimer = null;
      }
      state.nativeAttentionIdentityRetryCount = 0;
      if (!transitionIsStillNeeded()) {
        state.nativeAttentionInFlight = false;
        synchronizeNativeAttention(state);
        return;
      }
      const action = attemptedVisibility ? "begin" : "end";
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
        attemptedEpisode.scopeId,
        "--observation-id",
        attemptedEpisode.observationId,
        "--session-id",
        state.sessionId,
      ];
      if (attemptedVisibility) {
        args.push(
          "--workspace-id",
          workspaceId,
          "--surface-id",
          surfaceId,
        );
      }
      runCmuxAcknowledged(args, (succeeded) => {
        state.nativeAttentionInFlight = false;
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
              return;
            }
          } else {
            state.nativeAttentionRetryCount = 0;
          }
        }
        synchronizeNativeAttention(state);
      });
    });
  };

  const beginNativeAttention = (state: AmpTurnState): void => {
    if (!state.nativeAttentionDesiredEpisode) {
      if (state.nativeAttentionIdentityRetryTimer) {
        clearTimeout(state.nativeAttentionIdentityRetryTimer);
        state.nativeAttentionIdentityRetryTimer = null;
      }
      state.nativeAttentionIdentityRetryCount = 0;
      state.nativeAttentionDesiredEpisode = makeNativeAttentionEpisode();
    }
    synchronizeNativeAttention(state);
  };

  const endNativeAttention = (state: AmpTurnState): void => {
    if (state.nativeAttentionIdentityRetryTimer) {
      clearTimeout(state.nativeAttentionIdentityRetryTimer);
      state.nativeAttentionIdentityRetryTimer = null;
    }
    state.nativeAttentionIdentityRetryCount = 0;
    state.nativeAttentionDesiredEpisode = null;
    synchronizeNativeAttention(state);
  };

  const clearNativeStateObservation = (state: AmpTurnState): void => {
    state.nativeStateObservationEpoch += 1;
    if (state.nativeStateObservationLease) {
      clearTimeout(state.nativeStateObservationLease);
      state.nativeStateObservationLease = null;
    }
    if (state.nativeAttentionIdentityRetryTimer) {
      clearTimeout(state.nativeAttentionIdentityRetryTimer);
      state.nativeAttentionIdentityRetryTimer = null;
    }
    state.nativeAttentionIdentityRetryCount = 0;
    state.nativeStateSubscription?.unsubscribe();
    state.nativeStateSubscription = null;
    state.nativeStateObservable = null;
    state.nativeThreadState = null;
  };

  const discardTurnState = (
    threadId: string,
    state: AmpTurnState | undefined,
  ): void => {
    if (!state) return;
    clearNativeStateObservation(state);
    endNativeAttention(state);
    if (turnStates.get(threadId) === state) {
      turnStates.delete(threadId);
    }
  };

  const touchTurnState = (
    threadId: string,
    state: AmpTurnState,
  ): void => {
    if (turnStates.get(threadId) !== state) return;
    turnStates.delete(threadId);
    turnStates.set(threadId, state);
  };

  const retainTurnState = (
    threadId: string,
    state: AmpTurnState,
  ): void => {
    const existing = turnStates.get(threadId);
    if (existing && existing !== state) {
      discardTurnState(threadId, existing);
    }
    turnStates.delete(threadId);
    turnStates.set(threadId, state);
    while (turnStates.size > maximumRetainedTurnStateCount) {
      const oldest = turnStates.entries().next().value;
      if (!oldest) break;
      discardTurnState(oldest[0], oldest[1]);
    }
  };

  const renewNativeStateObservationLease = (
    threadId: string,
    state: AmpTurnState,
    observationEpoch: number,
  ): void => {
    if (
      turnStates.get(threadId) !== state
      || state.nativeStateObservationEpoch !== observationEpoch
    ) {
      return;
    }
    touchTurnState(threadId, state);
    if (state.nativeStateObservationLease) {
      clearTimeout(state.nativeStateObservationLease);
      state.nativeStateObservationLease = null;
    }
    // Once agent.end is pending, only an observed terminal state, a matching
    // tool result, or process exit can safely retire the turn. A wall-clock
    // lease would discard durable work evidence from long-running tools.
    if (
      state.pendingEnd
      || state.activeToolUseIds.size > 0
      || state.nativeThreadState === "awaiting-approval"
    ) {
      return;
    }
    state.nativeStateObservationLease = setTimeout(() => {
      if (
        turnStates.get(threadId) !== state
        || state.nativeStateObservationEpoch !== observationEpoch
      ) {
        return;
      }
      state.nativeStateObservationLease = null;
      // A rejected/hung snapshot plus a silent subscription cannot prove a
      // settled boundary. Retire our observer and turn ownership without
      // publishing a false completion; a later agent event starts fresh.
      discardTurnState(threadId, state);
    }, activeNativeStateObservationLeaseMilliseconds);
    state.nativeStateObservationLease.unref?.();
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
          setStatus("done", "checkmark.circle", COLOR.done);
          wsLog("turn complete", "success");
          break;
        case "error":
          setStatus("error", "xmark.circle", COLOR.error);
          wsLog("turn errored", "error");
          break;
        case "cancelled":
          setStatus("interrupted", "pause.circle", COLOR.interrupted);
          wsLog("turn interrupted", "warning");
          break;
        default:
          setStatus(
            String(pendingEnd.event.status ?? "done"),
            "questionmark.circle",
            COLOR.interrupted,
          );
          wsLog(
            `turn ended with unexpected status: ${pendingEnd.event.status}`,
            "warning",
          );
          break;
      }
    }
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
    const pendingEnd = state.pendingEnd;
    if (!pendingEnd || state.activeToolUseIds.size > 0) return;
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
      renewNativeStateObservationLease(
        threadId,
        state,
        state.nativeStateObservationEpoch,
      );
      tryPublishSettledTurn(threadId, state);
      return;
    }

    clearNativeStateObservation(state);
    const observationEpoch = state.nativeStateObservationEpoch;
    const applyNativeState = (nativeState: AmpNativeThreadState): void => {
      if (
        turnStates.get(threadId) !== state
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
      if (nativeState === "error") {
        // Amp can terminate an errored/cancelled turn without emitting a final
        // tool.result. Its terminal native state closes those tool lifetimes.
        state.activeToolUseIds.clear();
      }
      tryPublishSettledTurn(threadId, state);
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
          turnStates.get(threadId) !== state
          || state.nativeStateObservationEpoch !== observationEpoch
        ) {
          return;
        }
        didReceiveSubscriptionState = true;
        resolveSubscriptionState?.();
        resolveSubscriptionState = null;
        applyNativeState(nativeState);
        renewNativeStateObservationLease(
          threadId,
          state,
          observationEpoch,
        );
      });
      if (
        turnStates.get(threadId) === state
        && state.nativeStateObservationEpoch === observationEpoch
      ) {
        state.nativeStateSubscription = subscription;
      } else {
        subscription.unsubscribe();
      }
    } catch (_) {
      state.nativeStateSubscription = null;
    }
    renewNativeStateObservationLease(threadId, state, observationEpoch);

    let acceptsInitialSnapshot = true;
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
        // A present-but-failing native state API is not evidence of settlement.
      });
    let snapshotDeadline: ReturnType<typeof setTimeout> | null = null;
    const snapshotTimedOut = new Promise<void>((resolve) => {
      snapshotDeadline = setTimeout(
        resolve,
        nativeStateSnapshotDeadlineMilliseconds,
      );
    });
    try {
      await Promise.race([
        snapshotState,
        subscriptionState,
        snapshotTimedOut,
      ]);
      if (turnStates.get(threadId) === state) {
        tryPublishSettledTurn(threadId, state);
      }
    } finally {
      acceptsInitialSnapshot = false;
      if (snapshotDeadline) clearTimeout(snapshotDeadline);
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
    } catch (_) {}
  });

  amp.on("session.start", async (event: SessionStartEvent, ctx) => {
    const sessionId = threadIdFrom(event, ctx);
    if (sessionId) {
      discardTurnState(sessionId, turnStates.get(sessionId));
    }
    setStatus("idle", "circle", COLOR.idle);
    if (!sessionId) return;
    sendHook("session-start", sessionId, cwdFromEnv());
  });

  amp.on("agent.start", async (event: AgentStartEvent, ctx) => {
    const sessionId = threadIdFrom(event, ctx);
    if (!sessionId) return;
    discardTurnState(sessionId, turnStates.get(sessionId));
    const state = makeTurnState(event, sessionId);
    retainTurnState(sessionId, state);
    setStatus("thinking", "brain", COLOR.thinking);
    wsLog("prompt received");
    sendHook("prompt-submit", sessionId, cwdFromEnv(), {
      turn_id: state.turnId,
    });
    await observeNativeThreadState(sessionId, state, ctx);
  });

  amp.on("tool.call", async (event: ToolCallEvent, ctx) => {
    const sessionId = threadIdFrom(event, ctx);
    const state = sessionId ? turnStates.get(sessionId) : undefined;
    if (state) {
      state.activeToolUseIds.add(event.toolUseID);
      renewNativeStateObservationLease(
        state.sessionId,
        state,
        state.nativeStateObservationEpoch,
      );
    }
    const { label, icon } = detailedToolStatus(event, helpers);
    if (state) {
      setStatus(label, icon, COLOR.active);
    }
    return { action: "allow" as const };
  });

  amp.on("tool.result", async (event: ToolResultEvent, ctx) => {
    const sessionId = threadIdFrom(event, ctx);
    const state = sessionId ? turnStates.get(sessionId) : undefined;
    if (state) {
      state.activeToolUseIds.delete(event.toolUseID);
      renewNativeStateObservationLease(
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
    } else if (state && state.activeToolUseIds.size === 0) {
      setStatus("thinking", "brain", COLOR.thinking);
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
      cmux_active_background_work_count: state.activeToolUseIds.size,
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
                if existing.isEmpty {
                    try Self.ampExtensionSource.write(
                        to: extensionURL,
                        atomically: true,
                        encoding: .utf8
                    )
                    return
                }
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
