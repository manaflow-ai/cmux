extension CMUXCLI {
    static let piExtensionSourcePart1 = #"""
// cmux-pi-session-extension-marker v2
// Bridges Pi session lifecycle, tool telemetry, notifications, and resume bindings into cmux.
// Installed by `cmux hooks pi install` or `cmux hooks setup`.
// DO NOT EDIT MANUALLY. cmux upgrades this file in place.

import { Buffer } from "node:buffer";
import { spawn } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

type HookExtra = Record<string, unknown>;

interface PendingCompletion {
  lastAssistantMessage?: string;
  notificationType: string;
  turnId: string;
}

interface SessionState {
  nextTurn: number;
  activeTurnId?: string;
  pendingCompletion?: PendingCompletion;
  stopped: boolean;
}

interface CommandResult {
  ok: boolean;
  status: number | null;
  stdout: string;
  stderr: string;
  error?: unknown;
  surfaceUnavailable?: boolean;
}

interface PiExtensionContextSnapshot {
  readonly sessionId: string | null;
  readonly cwd: string;
  readonly notifyWarning?: () => void;
}

function firstString(...values: unknown[]): string | null {
  for (const value of values) {
    if (typeof value === "string" && value.trim().length > 0) return value.trim();
  }
  return null;
}

function objectValue(value: unknown, keys: string[]): unknown {
  if (!value || typeof value !== "object") return undefined;
  const typed = value as Record<string, unknown>;
  for (const key of keys) {
    if (typed[key] !== undefined && typed[key] !== null) return typed[key];
  }
  return undefined;
}

function utf8Prefix(value: unknown, maximumBytes: number): string | undefined {
  if (typeof value !== "string") return undefined;
  const bytes = Buffer.from(value, "utf8");
  if (bytes.byteLength <= maximumBytes) return value;
  return bytes.subarray(0, maximumBytes).toString("utf8").replace(/\uFFFD+$/u, "");
}

function boundedPiFeedInput(payload: Record<string, unknown>, maximumBytes: number): string {
  const serialized = JSON.stringify(payload);
  if (Buffer.byteLength(serialized, "utf8") <= maximumBytes) return serialized;

  const summaries = Array.isArray(payload.cmux_compacted_terminal_events)
    ? payload.cmux_compacted_terminal_events
    : [];
  const latest = summaries.length > 0 && typeof summaries[summaries.length - 1] === "object"
    ? summaries[summaries.length - 1] as Record<string, unknown>
    : undefined;
  const rawCount = payload.cmux_compacted_terminal_count;
  const totalCount = typeof rawCount === "number" && Number.isFinite(rawCount)
    ? Math.max(summaries.length, rawCount)
    : summaries.length;
  const rawOmitted = payload.cmux_compacted_terminal_omitted_count;
  const omittedCount = typeof rawOmitted === "number" && Number.isFinite(rawOmitted)
    ? Math.max(0, rawOmitted, totalCount - 1)
    : Math.max(0, totalCount - 1);
  const safe: Record<string, unknown> = {};
  for (const key of ["session_id", "cwd", "turn_id", "tool_call_id", "tool_name"] as const) {
    const value = utf8Prefix(payload[key], 256);
    if (value !== undefined) safe[key] = value;
  }
  for (const key of ["hook_event_name", "event"] as const) {
    const value = utf8Prefix(payload[key], 64);
    if (value !== undefined) safe[key] = value;
  }
  if (typeof payload.is_error === "boolean") safe.is_error = payload.is_error;
  if (latest) {
    const summary: Record<string, unknown> = {};
    for (const key of ["session_id", "cwd", "turn_id", "tool_call_id", "tool_name"] as const) {
      const value = utf8Prefix(latest[key] ?? payload[key], 256);
      if (value !== undefined) summary[key] = value;
    }
    if (typeof latest.is_error === "boolean") summary.is_error = latest.is_error;
    safe.cmux_compacted_terminal_count = totalCount;
    safe.cmux_compacted_terminal_omitted_count = omittedCount;
    safe.cmux_compacted_terminal_events = [summary];
  } else if (payload.tool_input && typeof payload.tool_input === "object") {
    safe.tool_input = payload.tool_input;
  }

  const compacted = JSON.stringify(safe);
  if (Buffer.byteLength(compacted, "utf8") <= maximumBytes) return compacted;
  return JSON.stringify({
    session_id: utf8Prefix(payload.session_id, 128),
    hook_event_name: "PostToolUse",
    event: "PostToolUse",
    tool_call_id: "compacted-overflow",
    tool_name: "cmux_compacted_terminal_overflow",
    tool_input: { omitted_terminal_count: Math.max(1, totalCount) },
  });
}

function resolveExecutable(name: string): string {
  const pathEnv = process.env.PATH || "";
  for (const dir of pathEnv.split(path.delimiter)) {
    if (!dir) continue;
    const candidate = path.join(dir, name);
    try {
      fs.accessSync(candidate, fs.constants.X_OK);
      if (fs.statSync(candidate).isFile()) return candidate;
    } catch (_) {}
  }
  return name;
}

function looksLikePiExecutable(value: string): boolean {
  const base = path.basename(value).toLowerCase();
  return base === "pi" || base === "pi-coding-agent";
}

function looksLikePiScript(value: string): boolean {
  const normalized = value.replaceAll("\\", "/").toLowerCase();
  const base = path.basename(normalized);
  return (
    normalized.includes("/@earendil-works/pi-coding-agent/") ||
    normalized.includes("/@mariozechner/pi-coding-agent/") ||
    normalized.includes("/packages/coding-agent/") ||
    ((base === "cli.js" || base === "cli.ts") &&
      (normalized.includes("pi-coding-agent") || normalized.includes("coding-agent")))
  );
}

function normalizedLaunchArgv(): string[] {
  const raw = Array.isArray(process.argv) ? process.argv.map((value) => String(value)) : [];
  if (raw.length === 0) return [resolveExecutable("pi")];
  if (looksLikePiExecutable(raw[0])) return raw;
  if (raw.length > 1 && looksLikePiScript(raw[1])) {
    return [resolveExecutable("pi"), ...raw.slice(2)];
  }
  return [resolveExecutable("pi"), ...raw.slice(1)];
}

function detectedPiVersion(): string | null {
  const script = process.argv.slice(0, 2).find((value) => {
    const candidate = String(value);
    return looksLikePiScript(candidate) || looksLikePiExecutable(candidate);
  });
  if (!script) return null;
  let scriptPath = path.resolve(String(script));
  try {
    // npm launches through bin symlinks, so inspect the package containing the resolved script.
    scriptPath = fs.realpathSync(scriptPath);
  } catch (_) {}
  let directory = path.dirname(scriptPath);
  for (let depth = 0; depth < 8; depth += 1) {
    try {
      const packageJSON = JSON.parse(fs.readFileSync(path.join(directory, "package.json"), "utf8"));
      if (
        packageJSON?.name === "@earendil-works/pi-coding-agent" ||
        packageJSON?.name === "@mariozechner/pi-coding-agent"
      ) {
        return firstString(packageJSON.version);
      }
    } catch (_) {}
    const parent = path.dirname(directory);
    if (parent === directory) break;
    directory = parent;
  }
  return null;
}

function supportsAgentSettled(): boolean {
  const version = detectedPiVersion();
  if (!version) return false;
  const match = /^(\d+)\.(\d+)\.(\d+)/.exec(version);
  if (!match) return false;
  const major = Number(match[1]);
  const minor = Number(match[2]);
  const patch = Number(match[3]);
  return major > 0 || minor > 80 || (minor === 80 && patch >= 5);
}

function base64NulSeparated(values: string[]): string {
  const bytes: Buffer[] = [];
  for (const value of values) {
    bytes.push(Buffer.from(String(value), "utf8"));
    bytes.push(Buffer.from([0]));
  }
  return Buffer.concat(bytes).toString("base64");
}

function secretLikeEnvKey(key: string): boolean {
  return /(TOKEN|SECRET|PASSWORD|PASSWD|API[_-]?KEY|ACCESS[_-]?KEY|PRIVATE[_-]?KEY|CREDENTIAL|AUTHORIZATION|COOKIE)/i.test(key);
}

function safePiEnvKey(key: string): boolean {
  return (
    key === "PI_CODING_AGENT_DIR" ||
    key === "PI_CONFIG_DIR" ||
    key === "PI_CODING_AGENT_SESSION_DIR" ||
    (key.startsWith("PI_CODING_AGENT_") && !secretLikeEnvKey(key))
  );
}

function safeNodeEnvKey(key: string): boolean {
  return (
    key === "NODE_ENV" ||
    key === "NODE_OPTIONS" ||
    key === "NODE_PATH" ||
    key === "NODE_NO_WARNINGS" ||
    key === "NODE_EXTRA_CA_CERTS"
  );
}

function safeCmuxEnvKey(key: string): boolean {
  if (key.startsWith("CMUX_TEST_PI_")) return !secretLikeEnvKey(key);
  if (key.startsWith("CMUX_AGENT_LAUNCH_")) return !secretLikeEnvKey(key);
  if (key === "CMUX_AGENT_HOOK_STATE_DIR") return true;
  if (key === "CMUX_PI_CMUX_BIN" || key === "CMUX_PI_HOOKS_DISABLED") return true;
  if (key === "CMUX_SURFACE_ID" || key === "CMUX_WORKSPACE_ID" || key === "CMUX_WINDOW_ID") return true;
  if (key === "CMUX_PANE_ID" || key === "CMUX_TAB_ID" || key === "CMUX_PANEL_ID") return true;
  if (key === "CMUX_SOCKET" || key === "CMUX_SOCKET_PATH") return true;
  if (key === "CMUX_BUNDLE_ID" || key === "CMUX_BUNDLED_CLI_PATH") return true;
  if (key === "CMUX_CLI_SENTRY_DISABLED" || key === "CMUX_DEBUG_LOG") return true;
  return false;
}

function shouldPreserveEnvKey(key: string): boolean {
  if (safeCmuxEnvKey(key)) return true;
  if (safePiEnvKey(key)) return true;
  if (safeNodeEnvKey(key)) return true;
  if (key === "PATH" || key === "HOME" || key === "PWD" || key === "SHELL") return true;
  if (key === "USER" || key === "LOGNAME" || key === "TMPDIR" || key === "TZ") return true;
  if (key === "LANG" || key.startsWith("LC_")) return true;
  if (key === "TERM" || key === "TERM_PROGRAM" || key === "TERM_PROGRAM_VERSION" || key === "COLORTERM") return true;
  if (key === "SSH_AUTH_SOCK") return true;
  if (key.startsWith("PI_") || key.startsWith("NODE_")) return !secretLikeEnvKey(key);
  return false;
}

function hookEnvironment(cwd: string, includeSocketPassword = false): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (value === undefined) continue;
    if (shouldPreserveEnvKey(key)) env[key] = value;
  }
  // Only cmux CLI children need the socket credential; keep it out of the generic allowlist.
  if (includeSocketPassword) {
    const socketPassword = process.env.CMUX_SOCKET_PASSWORD;
    if (socketPassword) env.CMUX_SOCKET_PASSWORD = socketPassword;
  }
  if (!env.CMUX_AGENT_LAUNCH_ARGV_B64) {
    const argv = normalizedLaunchArgv();
    env.CMUX_AGENT_LAUNCH_KIND = "pi";
    env.CMUX_AGENT_LAUNCH_EXECUTABLE = argv[0] || resolveExecutable("pi");
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
    case "notification":
      return "Notification";
    default:
      return subcommand;
  }
}

function textFromContent(content: unknown): string | null {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return null;
  const parts: string[] = [];
  for (const block of content) {
    if (!block || typeof block !== "object") continue;
    const typed = block as { type?: unknown; text?: unknown };
    if (typed.type === "text" && typeof typed.text === "string") parts.push(typed.text);
  }
  return parts.join("\n") || null;
}

function lastAssistantMessage(event: unknown): string | undefined {
  const messagesValue = objectValue(event, ["messages"]);
  const messages = Array.isArray(messagesValue) ? messagesValue : [];
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index];
    if (!message || typeof message !== "object") continue;
    const typed = message as { role?: unknown; content?: unknown };
    if (typed.role !== "assistant") continue;
    const text = firstString(textFromContent(typed.content));
    if (text) return text;
  }
  return undefined;
}

function sessionIdFrom(ctx: ExtensionContext): string | null {
  return firstString(ctx.sessionManager.getSessionId());
}

function cwdFrom(ctx: ExtensionContext): string {
  return firstString(ctx.cwd, process.cwd()) || process.cwd();
}

function snapshotContext(ctx: ExtensionContext): PiExtensionContextSnapshot {
  let notifyWarning: (() => void) | undefined;
  try {
    const ui = (ctx as unknown as { ui?: { notify?: (message: string, type?: string) => void } }).ui;
    if (typeof ui?.notify === "function") {
      notifyWarning = () => ui.notify?.("cmux Pi integration warning - check the terminal for details", "warning");
    }
  } catch (_) {}
  return {
    sessionId: sessionIdFrom(ctx),
    cwd: cwdFrom(ctx),
    notifyWarning,
  };
}

function stateFor(sessionStates: Map<string, SessionState>, sessionId: string): SessionState {
  let state = sessionStates.get(sessionId);
  if (!state) {
    state = { nextTurn: 0, stopped: false };
    sessionStates.set(sessionId, state);
  }
  return state;
}

function eventTurnId(event: unknown): string | null {
  return firstString(
    objectValue(event, ["turn_id", "turnId", "turnID"])
  );
}

function beginTurn(sessionStates: Map<string, SessionState>, sessionId: string, event: unknown): string {
  const state = stateFor(sessionStates, sessionId);
  const turnId = eventTurnId(event) || `${sessionId}:turn-${state.nextTurn + 1}`;
  if (!eventTurnId(event)) state.nextTurn += 1;
  state.activeTurnId = turnId;
  state.pendingCompletion = undefined;
  state.stopped = false;
  return turnId;
}

function currentTurnId(sessionStates: Map<string, SessionState>, sessionId: string, event: unknown): string {
  const state = stateFor(sessionStates, sessionId);
  const turnId = eventTurnId(event) || state.activeTurnId || `${sessionId}:turn-${state.nextTurn + 1}`;
  if (!eventTurnId(event) && !state.activeTurnId) state.nextTurn += 1;
  return turnId;
}

function finishTurn(sessionStates: Map<string, SessionState>, sessionId: string, event: unknown): string {
  const state = stateFor(sessionStates, sessionId);
  const turnId = eventTurnId(event) || state.activeTurnId || `${sessionId}:turn-${state.nextTurn + 1}`;
  if (!eventTurnId(event) && !state.activeTurnId) state.nextTurn += 1;
  state.activeTurnId = undefined;
  state.pendingCompletion = undefined;
  state.stopped = true;
  return turnId;
}

function settleTurn(sessionStates: Map<string, SessionState>, sessionId: string): PendingCompletion | undefined {
  const state = sessionStates.get(sessionId);
  const completion = state?.pendingCompletion;
  if (!state || !completion || state.stopped) return undefined;
  state.activeTurnId = undefined;
  state.pendingCompletion = undefined;
  // Keep the settlement claim while awaiting delivery so session_shutdown cannot
  // emit a second Stop when terminal-feed delivery degrades.
  state.stopped = true;
  return completion;
}

function warn(ctx: PiExtensionContextSnapshot | null, message: string, details: Record<string, unknown> = {}): void {
  const payload = { source: "cmux-pi-extension", level: "warning", message, ...details };
  try {
    console.warn(JSON.stringify(payload));
  } catch (_) {
    console.warn(`[cmux-pi-extension] ${message}`);
  }
  try {
    ctx?.notifyWarning?.();
  } catch (_) {}
}

function cmuxExecutable(): string {
  return process.env.CMUX_PI_CMUX_BIN || "cmux";
}

type SurfaceDispatchState = "unknown" | "available" | "unavailable";

interface PiFeedCommand {
  readonly args: string[];
  readonly cwd: string;
  readonly input: string;
  readonly context: PiExtensionContextSnapshot;
  readonly terminal: boolean;
}

interface PiCommandCancellation {
  cancelled: boolean;
  cancel?: () => void;
}
"""#
}
