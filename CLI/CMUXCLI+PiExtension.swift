import Foundation

extension CMUXCLI {
    private static let piExtensionMarker = "cmux-pi-session-extension-marker"
    private static let piExtensionFilename = "cmux-session.ts"
    private static let piExtensionSource = #"""
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
  if (key.startsWith("CMUX_TEST_PI_")) return true;
  if (key.startsWith("CMUX_AGENT_LAUNCH_")) return true;
  if (key === "CMUX_AGENT_HOOK_STATE_DIR") return true;
  if (key === "CMUX_PI_CMUX_BIN" || key === "CMUX_PI_HOOKS_DISABLED") return true;
  if (key === "CMUX_SURFACE_ID" || key === "CMUX_WORKSPACE_ID" || key === "CMUX_WINDOW_ID") return true;
  if (key === "CMUX_PANE_ID" || key === "CMUX_TAB_ID" || key === "CMUX_PANEL_ID") return true;
  if (key === "CMUX_SOCKET" || key === "CMUX_SOCKET_PATH") return true;
  if (key === "CMUX_BUNDLE_ID" || key === "CMUX_BUNDLED_CLI_PATH") return true;
  if (key === "CMUX_CLI_SENTRY_DISABLED" || key === "CMUX_DEBUG_LOG") return true;
  return key.startsWith("CMUX_") && !secretLikeEnvKey(key);
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
    objectValue(event, ["turn_id", "turnId", "turnID"]),
    objectValue(event, ["id", "request_id", "requestId"])
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
}

function sendHook(subcommand: string, ctx: ExtensionContext, extra: HookExtra = {}): boolean {
  if (process.env.CMUX_PI_HOOKS_DISABLED === "1") return true;
  if (!process.env.CMUX_SURFACE_ID) return true;

  const sessionId = sessionIdFrom(ctx);
  if (!sessionId) return true;

  const cwd = cwdFrom(ctx);
  const payload: HookExtra = {
    session_id: sessionId,
    cwd,
    hook_event_name: eventName(subcommand),
    event: eventName(subcommand),
    ...extra,
  };
  const result = runCmux(["hooks", "pi", subcommand], cwd, JSON.stringify(payload));
  if (!result.ok) {
    warn(ctx, "cmux hook command failed", {
      subcommand,
      status: result.status,
      stderr: result.stderr.trim(),
      error: result.error ? String(result.error) : undefined,
    });
  }
  return result.ok;
}

function surfaceTargetArgs(): string[] | null {
  const surfaceId = firstString(process.env.CMUX_SURFACE_ID);
  if (!surfaceId) return null;
  const args: string[] = [];
  const workspaceId = firstString(process.env.CMUX_WORKSPACE_ID);
  if (workspaceId) args.push("--workspace", workspaceId);
  args.push("--surface", surfaceId);
  return args;
}

function parseJSONOutput(result: CommandResult): Record<string, unknown> | null {
  if (!result.ok) return null;
  try {
    const parsed = JSON.parse(result.stdout);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed as Record<string, unknown> : null;
  } catch (_) {
    return null;
  }
}

function resumeBindingMatches(payload: Record<string, unknown> | null, sessionId: string): boolean {
  const binding = payload?.resume_binding;
  if (!binding || typeof binding !== "object") return false;
  const typed = binding as Record<string, unknown>;
  return firstString(typed.kind) === "pi" &&
    firstString(typed.checkpoint_id, typed.checkpointId) === sessionId;
}

const piOptionsWithValue = new Set([
  "--model",
  "-m",
  "--thinking",
  "--provider",
  "--extension",
  "-e",
  "--skill",
  "--mcp-config",
  "--permission-mode",
  "--session-dir",
  "--config",
  "--profile",
  "--system-prompt",
  "--append-system-prompt",
  "--cwd",
  "--dir",
  "--trust",
  "--sandbox",
]);

const piOptionsWithoutValue = new Set([
  "--no-color",
  "--dangerously-skip-permissions",
  "--yolo",
]);

const piSelectorsToDrop = new Set([
  "--session",
  "-s",
  "--resume",
  "--fork",
  "--api-key",
  "--prompt",
  "--print",
]);

function sanitizedResumeArgv(sessionId: string): string[] {
  const raw = normalizedLaunchArgv();
  const executable = raw[0] || resolveExecutable("pi");
  const out = [executable, "--session", sessionId];
  for (let index = 1; index < raw.length; index += 1) {
    const arg = raw[index];
    if (!arg) continue;
    if (piSelectorsToDrop.has(arg)) {
      if (index + 1 < raw.length && !raw[index + 1].startsWith("-")) index += 1;
      continue;
    }
    if (
      arg.startsWith("--session=") ||
      arg.startsWith("--resume=") ||
      arg.startsWith("--fork=") ||
      arg.startsWith("--api-key=") ||
      arg.startsWith("--prompt=")
    ) {
      continue;
    }
    if (piOptionsWithValue.has(arg)) {
      out.push(arg);
      if (index + 1 < raw.length) {
        out.push(raw[index + 1]);
        index += 1;
      }
      continue;
    }
    if ([...piOptionsWithValue].some((option) => arg.startsWith(`${option}=`)) || piOptionsWithoutValue.has(arg)) {
      out.push(arg);
    }
  }
  return out;
}

function ensureResumeBinding(ctx: ExtensionContext, sessionId: string, cwd: string): void {
  const target = surfaceTargetArgs();
  if (!target) return;

  const initial = runCmux(["--json", "surface", "resume", "get", ...target], cwd);
  const initialPayload = parseJSONOutput(initial);
  if (resumeBindingMatches(initialPayload, sessionId)) return;

  if (!initial.ok) {
    warn(ctx, "failed to read Pi resume binding", {
      status: initial.status,
      stderr: initial.stderr.trim(),
      error: initial.error ? String(initial.error) : undefined,
    });
  }

  const resumeArgv = sanitizedResumeArgv(sessionId);
  const set = runCmux([
    "--json",
    "surface",
    "resume",
    "set",
    ...target,
    "--name",
    "Pi",
    "--kind",
    "pi",
    "--checkpoint-id",
    sessionId,
    "--source",
    "agent-hook",
    "--cwd",
    cwd,
    "--",
    ...resumeArgv,
  ], cwd);
  if (!set.ok) {
    warn(ctx, "failed to set Pi resume binding", {
      status: set.status,
      stderr: set.stderr.trim(),
      error: set.error ? String(set.error) : undefined,
    });
    return;
  }

  const verified = parseJSONOutput(runCmux(["--json", "surface", "resume", "get", ...target], cwd));
  if (!resumeBindingMatches(verified, sessionId)) {
    warn(ctx, "Pi resume binding did not verify after write", { session_id: sessionId });
  }
}

function clearResumeBinding(ctx: ExtensionContext, sessionId: string, cwd: string): boolean {
  const target = surfaceTargetArgs();
  if (!target) return true;
  const result = runCmux([
    "--json",
    "surface",
    "resume",
    "clear",
    ...target,
    "--checkpoint-id",
    sessionId,
    "--source",
    "agent-hook",
  ], cwd);
  if (!result.ok) {
    warn(ctx, "failed to clear Pi resume binding", {
      status: result.status,
      stderr: result.stderr.trim(),
      error: result.error ? String(result.error) : undefined,
    });
  }
  return result.ok;
}

function sendFeed(eventName: "PreToolUse" | "PostToolUse", ctx: ExtensionContext, event: unknown, extra: HookExtra = {}): void {
  if (process.env.CMUX_PI_HOOKS_DISABLED === "1") return;
  if (!process.env.CMUX_SURFACE_ID) return;
  const sessionId = sessionIdFrom(ctx);
  if (!sessionId) return;
  const cwd = cwdFrom(ctx);
  const payload: HookExtra = {
    session_id: sessionId,
    cwd,
    hook_event_name: eventName,
    event: eventName,
    turn_id: currentTurnId(sessionId, event),
    tool_call_id: firstString(objectValue(event, ["toolCallId", "tool_call_id", "id"])),
    tool_name: firstString(objectValue(event, ["toolName", "tool_name", "name"])),
    tool_input: objectValue(event, ["args", "input"]),
    ...extra,
  };
  try {
    const child = spawn(cmuxExecutable(), ["hooks", "feed", "--source", "pi", "--event", eventName], {
      env: hookEnvironment(cwd, true),
      stdio: ["pipe", "ignore", "ignore"],
      detached: true,
    });
    child.on("error", () => {});
    child.stdin.on("error", () => {});
    child.stdin.end(JSON.stringify(payload));
    child.unref();
  } catch (_) {}
}

export default function cmuxPiSessionExtension(pi: ExtensionAPI) {
  pi.on("session_start", async (_event, ctx) => {
    const sessionId = sessionIdFrom(ctx);
    const cwd = cwdFrom(ctx);
    if (sessionId) stateFor(sessionId).stopped = false;
    const ok = sendHook("session-start", ctx);
    if (ok && sessionId) ensureResumeBinding(ctx, sessionId, cwd);
  });

  pi.on("before_agent_start", async (event, ctx) => {
    const sessionId = sessionIdFrom(ctx);
    const turnId = sessionId ? beginTurn(sessionId, event) : undefined;
    sendHook("prompt-submit", ctx, { prompt: event.prompt, turn_id: turnId });
  });

  pi.on("tool_execution_start", async (event, ctx) => {
    sendFeed("PreToolUse", ctx, event);
  });

  pi.on("tool_execution_end", async (event, ctx) => {
    sendFeed("PostToolUse", ctx, event, {
      tool_result: objectValue(event, ["result", "details", "content"]),
      is_error: objectValue(event, ["isError", "is_error"]),
    });
  });

  pi.on("agent_end", async (event, ctx) => {
    const sessionId = sessionIdFrom(ctx);
    const turnId = sessionId ? finishTurn(sessionId, event) : undefined;
    const message = lastAssistantMessage(event);
    sendHook("stop", ctx, {
      last_assistant_message: message,
      turn_id: turnId,
      cmux_notification_routed: true,
    });
    sendHook("notification", ctx, {
      message: message || "Task completed",
      turn_id: turnId,
      notification: {
        type: firstString(objectValue(event, ["stopReason", "reason", "terminationReason"])) || "completed",
      },
    });
  });

  pi.on("session_shutdown", async (event, ctx) => {
    const sessionId = sessionIdFrom(ctx);
    if (!sessionId) return;
    const state = stateFor(sessionId);
    const cwd = cwdFrom(ctx);
    if (!state.stopped) {
      const turnId = finishTurn(sessionId, event);
      sendHook("stop", ctx, {
        turn_id: turnId,
        terminationReason: firstString(objectValue(event, ["reason"])) || "session_shutdown",
        cmux_notification_routed: true,
      });
    }
    if (clearResumeBinding(ctx, sessionId, cwd)) sessionStates.delete(sessionId);
  });
}
"""#

    private func piExtensionURL(for def: AgentHookDef) -> URL {
        URL(fileURLWithPath: def.resolvedConfigDir(), isDirectory: true)
            .appendingPathComponent("extensions", isDirectory: true)
            .appendingPathComponent(Self.piExtensionFilename, isDirectory: false)
    }

    private func existingPiExtensionContents(at url: URL, fileManager: FileManager = .default) throws -> String {
        guard fileManager.fileExists(atPath: url.path) else { return "" }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            let message = String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.pi.error.readFailed",
                    defaultValue: "Failed to read %@"
                ),
                url.path
            )
            throw CLIError(message: "\(message): \((error as NSError).localizedDescription)")
        }
    }

    func installPiExtensionHooks(_ def: AgentHookDef) throws {
        let extensionURL = piExtensionURL(for: def)
        let fileManager = FileManager.default
        let skipConfirm = ProcessInfo.processInfo.arguments.contains("--yes")
            || ProcessInfo.processInfo.arguments.contains("-y")
        let existing = try existingPiExtensionContents(at: extensionURL, fileManager: fileManager)
        if existing == Self.piExtensionSource {
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.pi.alreadyUpToDate",
                    defaultValue: "Pi hooks already up to date at %@"
                ),
                extensionURL.path
            ))
            return
        }
        if !existing.isEmpty, !existing.contains(Self.piExtensionMarker) {
            throw CLIError(message: String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.pi.error.notCmuxExtension",
                    defaultValue: "%@ exists and is not a cmux extension; leaving it alone"
                ),
                extensionURL.path
            ))
        }
        if !skipConfirm {
            Self.printInstallPreview(
                path: extensionURL.path,
                oldContent: existing,
                newContent: Self.piExtensionSource,
                fallbackContent: Self.piExtensionSource
            )
            print(String(localized: "cli.hooks.pi.confirmProceed", defaultValue: "\nProceed? [y/N] "), terminator: "")
            guard readLine()?.lowercased().hasPrefix("y") == true else {
                print(String(localized: "cli.hooks.pi.aborted", defaultValue: "Aborted."))
                return
            }
        }
        try fileManager.createDirectory(
            at: extensionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.piExtensionSource.write(to: extensionURL, atomically: true, encoding: .utf8)
        print(String.localizedStringWithFormat(
            String(
                localized: "cli.hooks.pi.installed",
                defaultValue: "Pi hooks installed at %@"
            ),
            extensionURL.path
        ))
    }

    func uninstallPiExtensionHooks(_ def: AgentHookDef) throws {
        let extensionURL = piExtensionURL(for: def)
        let fm = FileManager.default
        guard fm.fileExists(atPath: extensionURL.path) else {
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.pi.noneFound",
                    defaultValue: "No Pi cmux extension found at %@"
                ),
                extensionURL.path
            ))
            return
        }
        let existing = try existingPiExtensionContents(at: extensionURL, fileManager: fm)
        guard existing.contains(Self.piExtensionMarker) else {
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.pi.refuseRemoveMissingMarker",
                    defaultValue: "Refusing to remove %@: missing cmux marker"
                ),
                extensionURL.path
            ))
            return
        }
        try fm.removeItem(at: extensionURL)
        print(String.localizedStringWithFormat(
            String(
                localized: "cli.hooks.pi.removed",
                defaultValue: "Removed Pi cmux extension from %@"
            ),
            extensionURL.path
        ))
    }
}
