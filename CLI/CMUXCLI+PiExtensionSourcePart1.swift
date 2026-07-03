extension CMUXCLI {
    static let piExtensionSourcePart1 = #"""
// cmux-pi-session-extension-marker v2
// Bridges Pi session lifecycle, tool telemetry, notifications, and resume bindings into cmux.
// Installed by `cmux hooks pi install` or `cmux hooks setup`.
// DO NOT EDIT MANUALLY. cmux upgrades this file in place.

import { spawn, spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

type HookExtra = Record<string, unknown>;

interface SessionState {
  nextTurn: number;
  activeTurnId?: string;
  stopped: boolean;
}

interface CommandResult {
  ok: boolean;
  status: number | null;
  stdout: string;
  stderr: string;
  error?: unknown;
}

const sessionStates = new Map<string, SessionState>();

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

function stateFor(sessionId: string): SessionState {
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

function beginTurn(sessionId: string, event: unknown): string {
  const state = stateFor(sessionId);
  const turnId = eventTurnId(event) || `${sessionId}:turn-${state.nextTurn + 1}`;
  if (!eventTurnId(event)) state.nextTurn += 1;
  state.activeTurnId = turnId;
  state.stopped = false;
  return turnId;
}

function currentTurnId(sessionId: string, event: unknown): string {
  const state = stateFor(sessionId);
  const turnId = eventTurnId(event) || state.activeTurnId || `${sessionId}:turn-${state.nextTurn + 1}`;
  if (!eventTurnId(event) && !state.activeTurnId) state.nextTurn += 1;
  return turnId;
}

function finishTurn(sessionId: string, event: unknown): string {
  const state = stateFor(sessionId);
  const turnId = eventTurnId(event) || state.activeTurnId || `${sessionId}:turn-${state.nextTurn + 1}`;
  if (!eventTurnId(event) && !state.activeTurnId) state.nextTurn += 1;
  state.activeTurnId = undefined;
  state.stopped = true;
  return turnId;
}

function warn(ctx: ExtensionContext | null, message: string, details: Record<string, unknown> = {}): void {
  const payload = { source: "cmux-pi-extension", level: "warning", message, ...details };
  try {
    console.warn(JSON.stringify(payload));
  } catch (_) {
    console.warn(`[cmux-pi-extension] ${message}`);
  }
  const ui = (ctx as unknown as { ui?: { notify?: (message: string, type?: string) => void } } | null)?.ui;
  try {
    ui?.notify?.("cmux Pi integration warning - check the terminal for details", "warning");
  } catch (_) {}
}

function cmuxExecutable(): string {
  return process.env.CMUX_PI_CMUX_BIN || "cmux";
}

function runCmux(args: string[], cwd: string, input?: string): CommandResult {
  try {
    const result = spawnSync(cmuxExecutable(), args, {
      input,
      encoding: "utf8",
      env: hookEnvironment(cwd, true),
      stdio: ["pipe", "pipe", "pipe"],
      timeout: 5000,
    });
    const status = typeof result.status === "number" ? result.status : null;
    return {
      ok: status === 0 && !result.error,
      status,
      stdout: typeof result.stdout === "string" ? result.stdout : "",
      stderr: typeof result.stderr === "string" ? result.stderr : "",
      error: result.error,
    };
  } catch (error) {
    return { ok: false, status: null, stdout: "", stderr: "", error };
  }
"""#
}
