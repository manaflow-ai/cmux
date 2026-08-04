import Foundation

extension CMUXCLI {
    private static let ampExtensionMarker = "cmux-amp-session-extension-marker"
    private static let ampExtensionFilename = "cmux-session.ts"
    private static let ampExtensionSource = #"""
// cmux-amp-session-extension-marker v2
// Bridges Amp session lifecycle events into cmux's restorable session store
// AND reports live agent status (idle/thinking/tool calls/done/error) into
// the cmux tab status bar.
// Installed by `cmux hooks amp install` or `cmux hooks setup`.
// DO NOT EDIT MANUALLY. cmux upgrades this file in place.
// @i-know-the-amp-plugin-api-is-wip-and-very-experimental-right-now

import { spawn, spawnSync } from "node:child_process";
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

type NativeAttentionProcessGeneration = {
  startSeconds: string;
  startMicroseconds: string;
};

function captureNativeAttentionProcessGeneration(): NativeAttentionProcessGeneration | null {
  if (process.env.CMUX_AMP_HOOKS_DISABLED === "1") return null;
  if (!process.env.CMUX_SURFACE_ID) return null;
  const cmux = process.env.CMUX_AMP_CMUX_BIN || "cmux";
  try {
    const child = spawnSync(
      cmux,
      [
        "hooks",
        "amp",
        "__native-attention",
        "identify",
        "--pid",
        String(process.pid),
      ],
      {
        env: statusEnvironment(),
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"],
        timeout: 2000,
      },
    );
    if (child.status !== 0 || typeof child.stdout !== "string") return null;
    const identity = JSON.parse(child.stdout) as {
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

const nativeAttentionProcessGeneration =
  captureNativeAttentionProcessGeneration();

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
  type AmpTurnState = {
    turnId: string;
    activeToolUseIds: Set<string>;
    pendingEnd: PendingTurnEnd | null;
    nativeStateObservable: AmpThreadStateObservable | null;
    nativeStateSubscription: AmpThreadStateSubscription | null;
    nativeThreadState: AmpNativeThreadState | null;
    attentionScopeId: string;
    attentionObservationId: string;
    isAttentionVisible: boolean;
  };

  // Amp plugin processes are long-lived and may serve multiple threads
  // concurrently. Tool liveness and provisional completion therefore belong
  // to a thread/turn, never to one process-global counter.
  const turnStates = new Map<string, AmpTurnState>();
  let turnSequence = 0;

  const makeTurnState = (
    event: { id?: unknown },
    threadId: string,
    forcedTurnId: string | null = null,
  ): AmpTurnState => {
    const sequence = ++turnSequence;
    return {
      turnId:
        forcedTurnId
        || firstString(event.id)
        || `${process.pid}:${threadId}:${Date.now()}:${sequence}`,
      activeToolUseIds: new Set(),
      pendingEnd: null,
      nativeStateObservable: null,
      nativeStateSubscription: null,
      nativeThreadState: null,
      attentionScopeId: `amp-scope-${process.pid}-${sequence}`,
      attentionObservationId:
        `amp-approval-${process.pid}-${sequence}`,
      isAttentionVisible: false,
    };
  };

  const beginNativeAttention = (state: AmpTurnState): void => {
    if (state.isAttentionVisible) return;
    if (!nativeAttentionProcessGeneration) return;
    const workspaceId = firstString(process.env.CMUX_WORKSPACE_ID);
    const surfaceId = firstString(process.env.CMUX_SURFACE_ID);
    if (!workspaceId || !surfaceId) return;
    state.isAttentionVisible = true;
    runCmux([
      "hooks",
      "amp",
      "__native-attention",
      "begin",
      "--pid",
      String(process.pid),
      "--pid-start-seconds",
      nativeAttentionProcessGeneration.startSeconds,
      "--pid-start-microseconds",
      nativeAttentionProcessGeneration.startMicroseconds,
      "--scope-id",
      state.attentionScopeId,
      "--observation-id",
      state.attentionObservationId,
      "--workspace-id",
      workspaceId,
      "--surface-id",
      surfaceId,
    ]);
  };

  const endNativeAttention = (state: AmpTurnState): void => {
    if (!state.isAttentionVisible) return;
    if (!nativeAttentionProcessGeneration) return;
    state.isAttentionVisible = false;
    runCmux([
      "hooks",
      "amp",
      "__native-attention",
      "end",
      "--pid",
      String(process.pid),
      "--pid-start-seconds",
      nativeAttentionProcessGeneration.startSeconds,
      "--pid-start-microseconds",
      nativeAttentionProcessGeneration.startMicroseconds,
      "--scope-id",
      state.attentionScopeId,
      "--observation-id",
      state.attentionObservationId,
    ]);
  };

  const discardTurnState = (
    threadId: string,
    state: AmpTurnState | undefined,
  ): void => {
    if (!state) return;
    state.nativeStateSubscription?.unsubscribe();
    state.nativeStateSubscription = null;
    endNativeAttention(state);
    if (turnStates.get(threadId) === state) {
      turnStates.delete(threadId);
    }
  };

  const hasOtherActiveTurn = (): boolean => turnStates.size > 0;

  const publishSettledTurn = (
    threadId: string,
    state: AmpTurnState,
    pendingEnd: PendingTurnEnd,
  ): void => {
    discardTurnState(threadId, state);
    if (!hasOtherActiveTurn()) {
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

    const applyNativeState = (nativeState: AmpNativeThreadState): void => {
      if (turnStates.get(threadId) !== state) return;
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
    state.nativeStateSubscription?.unsubscribe();
    let didReceiveSubscriptionState = false;
    state.nativeStateSubscription = observable.subscribe((nativeState) => {
      didReceiveSubscriptionState = true;
      applyNativeState(nativeState);
    });
    try {
      const initialState = await observable.get();
      if (
        !didReceiveSubscriptionState
        && state.nativeThreadState === null
      ) {
        applyNativeState(initialState);
      } else if (turnStates.get(threadId) === state) {
        tryPublishSettledTurn(threadId, state);
      }
    } catch (_) {
      // A present-but-failing native state API is not evidence of settlement.
      // Keep the provisional turn running until a subscription value arrives
      // or process-liveness reconciliation terminates the dead generation.
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
    setStatus("idle", "circle", COLOR.idle);
    const sessionId = threadIdFrom(event, ctx);
    if (!sessionId) return;
    discardTurnState(sessionId, turnStates.get(sessionId));
    sendHook("session-start", sessionId, cwdFromEnv());
  });

  amp.on("agent.start", async (event: AgentStartEvent, ctx) => {
    const sessionId = threadIdFrom(event, ctx);
    if (!sessionId) return;
    discardTurnState(sessionId, turnStates.get(sessionId));
    const state = makeTurnState(event, sessionId);
    turnStates.set(sessionId, state);
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
    if (state) state.activeToolUseIds.add(event.toolUseID);
    const { label, icon } = detailedToolStatus(event, helpers);
    if (state) {
      setStatus(label, icon, COLOR.active);
    }
    return { action: "allow" as const };
  });

  amp.on("tool.result", async (event: ToolResultEvent, ctx) => {
    const sessionId = threadIdFrom(event, ctx);
    const state = sessionId ? turnStates.get(sessionId) : undefined;
    if (state) state.activeToolUseIds.delete(event.toolUseID);
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
    turnStates.set(sessionId, state);
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

    func installAmpExtensionHooks(_ def: AgentHookDef) throws {
        let extensionURL = ampExtensionURL(for: def)
        let skipConfirm = ProcessInfo.processInfo.arguments.contains("--yes")
            || ProcessInfo.processInfo.arguments.contains("-y")
        let existing = (try? String(contentsOf: extensionURL, encoding: .utf8)) ?? ""
        if existing == Self.ampExtensionSource {
            print("Amp hooks already up to date at \(extensionURL.path)")
            return
        }
        if !existing.isEmpty, !existing.contains(Self.ampExtensionMarker) {
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
        try FileManager.default.createDirectory(
            at: extensionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.ampExtensionSource.write(to: extensionURL, atomically: true, encoding: .utf8)
        print("Amp hooks installed at \(extensionURL.path)")
    }

    func uninstallAmpExtensionHooks(_ def: AgentHookDef) throws {
        let extensionURL = ampExtensionURL(for: def)
        let fm = FileManager.default
        guard fm.fileExists(atPath: extensionURL.path) else {
            print("No Amp cmux plugin found at \(extensionURL.path)")
            return
        }
        let existing = (try? String(contentsOf: extensionURL, encoding: .utf8)) ?? ""
        guard existing.contains(Self.ampExtensionMarker) else {
            print("Refusing to remove \(extensionURL.path): missing cmux marker")
            return
        }
        try fm.removeItem(at: extensionURL)
        print("Removed Amp cmux plugin from \(extensionURL.path)")
    }
}
