import Foundation

extension CMUXCLI {
    private static let ompExtensionMarker = "cmux-omp-session-extension-marker"
    private static let ompExtensionFilename = "cmux-omp-session.ts"
    private static let ompExtensionSource = #"""
// cmux-omp-session-extension-marker v3
// Bridges OMP session lifecycle events into cmux's restorable session store.
// Installed by `cmux hooks omp install` or `cmux hooks setup`.
// DO NOT EDIT MANUALLY. cmux upgrades this file in place.

import { spawn } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import type { AgentEndEvent, ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";

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
      if (fs.statSync(candidate).isFile()) return candidate;
    } catch (_) {}
  }
  return name;
}

function looksLikeOmpExecutable(value: string): boolean {
  return path.basename(value).toLowerCase() === "omp";
}

function looksLikeOmpScript(value: string): boolean {
  const normalized = value.replaceAll("\\", "/").toLowerCase();
  const base = path.basename(normalized);
  return (
    normalized.includes("/@oh-my-pi/pi-coding-agent/") ||
    normalized.includes("/oh-my-pi/") ||
    ((base === "cli.js" || base === "cli.ts") && normalized.includes("pi-coding-agent"))
  );
}

function looksLikeJavaScriptRuntime(value: string): boolean {
  const base = path.basename(value).toLowerCase();
  return base === "node" || base === "bun" || base === "deno" || base === "tsx" || base === "ts-node";
}

function normalizedLaunchArgv(): string[] {
  const raw = Array.isArray(process.argv) ? process.argv.map((value) => String(value)) : [];
  if (raw.length === 0) return [resolveExecutable("omp")];
  if (looksLikeOmpExecutable(raw[0])) return raw;
  if (raw.length > 1 && (looksLikeOmpScript(raw[1]) || looksLikeJavaScriptRuntime(raw[0]))) {
    return [resolveExecutable("omp"), ...raw.slice(2)];
  }
  return [resolveExecutable("omp"), ...raw.slice(1)];
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
  env.CMUX_OMP_PID = String(process.pid);
  if (!env.CMUX_AGENT_LAUNCH_ARGV_B64) {
    const argv = normalizedLaunchArgv();
    env.CMUX_AGENT_LAUNCH_KIND = "omp";
    env.CMUX_AGENT_LAUNCH_EXECUTABLE = argv[0] || resolveExecutable("omp");
    env.CMUX_AGENT_LAUNCH_ARGV_B64 = base64NulSeparated(argv);
    env.CMUX_AGENT_LAUNCH_CWD = cwd || process.cwd();
  }
  return env;
}

interface HookInvocation {
  cmux: string;
  cwd: string;
  sessionId: string;
  payload: string;
  env: NodeJS.ProcessEnv;
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

function lastAssistantMessage(event: AgentEndEvent): string | undefined {
  for (let index = event.messages.length - 1; index >= 0; index -= 1) {
    const message = event.messages[index];
    if (!message || typeof message !== "object") continue;
    const typed = message as { role?: unknown; content?: unknown };
    if (typed.role !== "assistant") continue;
    const text = firstString(textFromContent(typed.content));
    if (text) return text;
  }
  return undefined;
}

function boundedHookText(value: string | undefined): string | undefined {
  if (value === undefined || value.length <= 32768) return value;
  return value.slice(0, 32768);
}

function isNestedArtifactSession(ctx: ExtensionContext): boolean {
  const sessionFile = firstString(ctx.sessionManager.getSessionFile());
  return sessionFile !== null && fs.existsSync(`${path.dirname(sessionFile)}.jsonl`);
}

function hookInvocation(subcommand: string, ctx: ExtensionContext, extra: Record<string, unknown> = {}): HookInvocation | null {
  if (process.env.CMUX_OMP_HOOKS_DISABLED === "1") return null;
  if (!process.env.CMUX_SURFACE_ID) return null;
  if (isNestedArtifactSession(ctx)) return null;

  const sessionId = firstString(ctx.sessionManager.getSessionId());
  if (!sessionId) return null;

  const cwd = firstString(ctx.cwd, process.cwd()) || process.cwd();
  const payload: Record<string, unknown> = {
    session_id: sessionId,
    cwd,
    hook_event_name: eventName(subcommand),
    event: eventName(subcommand),
    ...extra,
  };
  const cmux = process.env.CMUX_OMP_CMUX_BIN || "cmux";
  return {
    cmux,
    cwd,
    sessionId,
    payload: JSON.stringify(payload),
    env: hookEnvironment(cwd),
  };
}

interface RunningHook {
  completion: Promise<void>;
  cancel: () => void;
}

function startHook(invocation: HookInvocation, subcommand: string): RunningHook {
  let child: ReturnType<typeof spawn> | null = null;
  let settle = () => {};
  const terminate = () => {
    if (child && !child.killed) child.kill("SIGKILL");
  };
  const completion = new Promise<void>((resolve) => {
    let settled = false;
    const timeout = setTimeout(() => {
      terminate();
    }, 5000);
    timeout.unref();
    settle = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      resolve();
    };
    try {
      child = spawn(invocation.cmux, ["hooks", "omp", subcommand], {
        env: invocation.env,
        stdio: ["pipe", "ignore", "ignore"],
      });
      child.on("error", settle);
      child.on("close", settle);
      child.stdin.on("error", () => {});
      child.stdin.end(invocation.payload);
    } catch (_) {
      settle();
    }
  });
  return {
    completion,
    cancel: () => {
      terminate();
    },
  };
}

interface QueuedHook {
  invocation: HookInvocation;
  subcommand: string;
}

function hookPriority(subcommand: string): number {
  switch (subcommand) {
    case "stop":
      return 2;
    case "session-start":
      return 1;
    default:
      return 0;
  }
}

const maxQueuedHooks = 16;
const hookShutdownDeadlineMs = 2000;
const hookQueue: QueuedHook[] = [];
let hookWorker: Promise<void> | null = null;
let activeHook: RunningHook | null = null;
let activeHookSubcommand: string | null = null;

async function drainHookQueue(): Promise<void> {
  while (hookQueue.length > 0) {
    const next = hookQueue.shift();
    if (!next) continue;
    const running = startHook(next.invocation, next.subcommand);
    activeHook = running;
    activeHookSubcommand = next.subcommand;
    await running.completion;
    if (activeHook === running) {
      activeHook = null;
      activeHookSubcommand = null;
    }
  }
}

function startHookWorker(): void {
  if (hookWorker) return;
  hookWorker = drainHookQueue().finally(() => {
    hookWorker = null;
    if (hookQueue.length > 0) startHookWorker();
  });
}

async function waitForHookWorker(worker: Promise<void>, timeoutMs: number): Promise<boolean> {
  let completed = false;
  let timeout: ReturnType<typeof setTimeout> | null = null;
  await Promise.race([
    worker.then(() => {
      completed = true;
    }),
    new Promise<void>((resolve) => {
      timeout = setTimeout(resolve, timeoutMs);
    }),
  ]);
  if (timeout) clearTimeout(timeout);
  return completed;
}

async function awaitHookQueueDrain(): Promise<void> {
  for (let index = hookQueue.length - 1; index >= 0; index -= 1) {
    if (hookQueue[index]?.subcommand === "prompt-submit") hookQueue.splice(index, 1);
  }
  const worker = hookWorker;
  if (!worker) return;
  if (await waitForHookWorker(worker, hookShutdownDeadlineMs)) return;

  for (let index = hookQueue.length - 1; index >= 0; index -= 1) {
    if (hookQueue[index]?.subcommand !== "stop") hookQueue.splice(index, 1);
  }
  if (activeHookSubcommand !== "stop") activeHook?.cancel();
  if (await waitForHookWorker(worker, hookShutdownDeadlineMs)) return;

  hookQueue.splice(0);
  activeHook?.cancel();
  await worker;
}

function enqueueHook(invocation: HookInvocation, subcommand: string): void {
  const duplicate = hookQueue.findIndex(
    (queued) => queued.invocation.sessionId === invocation.sessionId && queued.subcommand === subcommand
  );
  if (duplicate >= 0) {
    hookQueue.splice(duplicate, 1);
    hookQueue.push({ invocation, subcommand });
  } else {
    if (hookQueue.length >= maxQueuedHooks) {
      const priority = hookPriority(subcommand);
      const evictable = hookQueue.findIndex((queued) => hookPriority(queued.subcommand) < priority);
      if (evictable >= 0) hookQueue.splice(evictable, 1);
      else return;
    }
    hookQueue.push({ invocation, subcommand });
  }
  startHookWorker();
}

function sendHook(subcommand: string, ctx: ExtensionContext, extra: Record<string, unknown> = {}): Promise<void> {
  const invocation = hookInvocation(subcommand, ctx, extra);
  if (!invocation) return Promise.resolve();
  enqueueHook(invocation, subcommand);
  return Promise.resolve();
}

// ── Feed telemetry (tool execution) ──────────────────────────────────────────

const subagentToolNames = new Set([
  "subagent",
  "team_spawn",
  "superpowers_dispatch",
  "Task",
]);

function isSubagentTool(event: unknown): boolean {
  const toolName = firstString(
    objectValue(event, ["toolName", "tool_name", "name"]),
  );
  return toolName !== null && (subagentToolNames.has(toolName) || /subagent/i.test(toolName));
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
  const candidate = value.length > maximumBytes ? value.slice(0, maximumBytes) : value;
  const bytes = Buffer.from(String(candidate), "utf8");
  if (bytes.byteLength <= maximumBytes) return candidate;
  return bytes.subarray(0, maximumBytes).toString("utf8").replace(/\uFFFD+$/u, "");
}

function displayToolName(name: string): string {
  return name.charAt(0).toUpperCase() + name.slice(1);
}

// Fire-and-forget feed telemetry: spawns `cmux hooks feed --source omp --event <event>`.
// Non-blocking — the agent never waits on this.
function sendFeed(
  eventName: string,
  ctx: ExtensionContext,
  event: unknown,
): void {
  if (process.env.CMUX_OMP_HOOKS_DISABLED === "1") return;
  if (!process.env.CMUX_SURFACE_ID) return;
  if (isNestedArtifactSession(ctx)) return;

  const sessionId = firstString(ctx.sessionManager.getSessionId());
  if (!sessionId) return;

  const cwd = firstString(ctx.cwd, process.cwd()) || process.cwd();
  const toolCallId = firstString(objectValue(event, ["toolCallId", "tool_call_id", "id"]));
  const toolName = firstString(objectValue(event, ["toolName", "tool_name", "name"]));
  const isError = objectValue(event, ["isError", "is_error"]);

  const payload: Record<string, unknown> = {
    session_id: utf8Prefix(sessionId, 256),
    cwd: utf8Prefix(cwd, 2048),
    hook_event_name: eventName,
    event: eventName,
  };
  const boundedToolCallId = utf8Prefix(toolCallId, 256);
  if (boundedToolCallId !== undefined) payload.tool_call_id = boundedToolCallId;
  const boundedToolName = utf8Prefix(toolName, 256);
  if (boundedToolName !== undefined) payload.tool_name = boundedToolName;
  // Security: tool_input can contain tokens, secrets, or auth headers from
  // bash commands. Do not send it to Feed — tool_name is enough for progress.
  if (isError !== undefined) payload.is_error = isError;

  const cmux = process.env.CMUX_OMP_CMUX_BIN || "cmux";
  try {
    const child = spawn(cmux, ["hooks", "feed", "--source", "omp", "--event", eventName], {
      env: hookEnvironment(cwd),
      stdio: ["pipe", "ignore", "ignore"],
    });
    child.on("error", () => {});
    child.stdin.on("error", () => {});
    child.stdin.end(JSON.stringify(payload));
    child.unref();
  } catch (_) {}
}

// Sidebar status: fire-and-forget `cmux set-status` / `cmux clear-status`.
// Shows "Running <tool>" while a tool is executing, cleared on agent_end.
function setSidebarStatus(key: string, value: string, icon?: string): void {
  if (process.env.CMUX_OMP_HOOKS_DISABLED === "1") return;
  if (!process.env.CMUX_SURFACE_ID) return;
  const cmux = process.env.CMUX_OMP_CMUX_BIN || "cmux";
  const args = ["set-status", key, value];
  if (icon) args.push("--icon", icon);
  try {
    const child = spawn(cmux, args, {
      env: hookEnvironment(process.cwd()),
      stdio: "ignore",
    });
    child.on("error", () => {});
    child.unref();
  } catch (_) {}
}

function clearSidebarStatus(key: string): void {
  if (process.env.CMUX_OMP_HOOKS_DISABLED === "1") return;
  if (!process.env.CMUX_SURFACE_ID) return;
  const cmux = process.env.CMUX_OMP_CMUX_BIN || "cmux";
  try {
    const child = spawn(cmux, ["clear-status", key], {
      env: hookEnvironment(process.cwd()),
      stdio: "ignore",
    });
    child.on("error", () => {});
    child.unref();
  } catch (_) {}
}

const ompStatusKey = "omp_agent";

// The pane's lifecycle in cmux must be owned by exactly one OMP session: the
// top-level session driving the terminal. Subagents spawned by the task tool
// run in the same process and inherit CMUX_SURFACE_ID, but each has its own
// session id; without an ownership check, every subagent's agent_end reports
// the whole pane idle while the main agent is still mid-turn, and Agent
// Hibernation then SIGHUPs the live pane (issue #9591).
//
// Ownership must live on globalThis, not in module scope: OMP loads a fresh
// copy of this module for every session in the process (each extension import
// uses a unique ?mtime= cache-busting URL), so module state is per-session
// while the pane is per-process.
interface CmuxOmpPaneOwnership {
  sessionId: string | null;
}

const cmuxOmpGlobals = globalThis as typeof globalThis & {
  __cmuxOmpPaneOwnership?: CmuxOmpPaneOwnership;
};

function paneOwnership(): CmuxOmpPaneOwnership {
  cmuxOmpGlobals.__cmuxOmpPaneOwnership ??= { sessionId: null };
  return cmuxOmpGlobals.__cmuxOmpPaneOwnership;
}

function contextSessionId(ctx: ExtensionContext): string | null {
  return firstString(ctx.sessionManager.getSessionId());
}

function isOwnerContext(ctx: ExtensionContext): boolean {
  const sessionId = contextSessionId(ctx);
  return sessionId !== null && sessionId === paneOwnership().sessionId;
}

export default function cmuxOmpSessionExtension(api: ExtensionAPI) {
  api.on("session_start", async (_event, ctx) => {
    // The top-level session bootstraps before any subagent can exist in this
    // process, so the first session_start pins ownership. Later session_start
    // events with a different session id are subagent bootstraps.
    const ownership = paneOwnership();
    if (ownership.sessionId === null) ownership.sessionId = contextSessionId(ctx);
    if (!isOwnerContext(ctx)) return;
    await sendHook("session-start", ctx);
  });

  // In-process session transitions (/new, fork, resume, handoff) fire only on
  // the top-level runtime; subagent sessions never switch or branch. Re-pin
  // ownership to the new session id and rebind the surface in cmux.
  const adoptSwitchedSession = async (_event: unknown, ctx: ExtensionContext) => {
    const sessionId = contextSessionId(ctx);
    if (!sessionId) return;
    const ownership = paneOwnership();
    // OMP's reload() re-emits session_switch for the unchanged session file.
    // A same-id "switch" is not an ownership transition: a spurious
    // session-start would mark an idle pane running with no agent_end coming.
    if (ownership.sessionId === sessionId) return;
    ownership.sessionId = sessionId;
    await sendHook("session-start", ctx);
  };
  api.on("session_switch", adoptSwitchedSession);
  api.on("session_branch", adoptSwitchedSession);

  api.on("before_agent_start", async (event, ctx) => {
    if (!isOwnerContext(ctx)) return;
    await sendHook("prompt-submit", ctx, { prompt: boundedHookText(event.prompt) });
  });

  api.on("tool_execution_start", (event, ctx) => {
    if (!isOwnerContext(ctx)) return;
    const toolName = firstString(objectValue(event, ["toolName", "tool_name", "name"])) || "tool";
    sendFeed(isSubagentTool(event) ? "SubagentStart" : "PreToolUse", ctx, event);
    setSidebarStatus(ompStatusKey, displayToolName(toolName), "hammer");
  });

  api.on("tool_execution_end", (event, ctx) => {
    if (!isOwnerContext(ctx)) return;
    sendFeed(isSubagentTool(event) ? "SubagentStop" : "PostToolUse", ctx, event);
  });

  api.on("agent_end", async (event, ctx) => {
    if (!isOwnerContext(ctx)) return;
    // OMP emits agent_end as the universal terminal settle. willContinue marks
    // a scheduled automatic continuation (auto-retry, queued messages,
    // session_stop continuations, background jobs), so the turn is still
    // logically running and the pane must not report idle yet. Read it
    // defensively: AgentEndEvent predates the field on older OMP versions.
    if ((event as { willContinue?: unknown }).willContinue === true) return;
    clearSidebarStatus(ompStatusKey);
    await sendHook("stop", ctx, { last_assistant_message: boundedHookText(lastAssistantMessage(event)) });
  });

  api.on("session_shutdown", async (_event, ctx) => {
    // A subagent session's teardown must not drain (and drop queued
    // prompt-submit entries of) the owner session's hook queue.
    if (!isOwnerContext(ctx)) return;
    clearSidebarStatus(ompStatusKey);
    await awaitHookQueueDrain();
  });
}
"""#

    static func resolvedOmpAgentDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let agentRoot = nonEmptyEnvironmentValue("PI_CODING_AGENT_DIR", in: environment) {
            return URL(
                fileURLWithPath: NSString(string: agentRoot).expandingTildeInPath,
                isDirectory: true
            )
        }

        let home = nonEmptyEnvironmentValue("HOME", in: environment) ?? NSHomeDirectory()
        let configDir = nonEmptyEnvironmentValue("PI_CONFIG_DIR", in: environment) ?? ".omp"
        let expandedConfigDir = NSString(string: configDir).expandingTildeInPath
        let configRoot: URL
        if (expandedConfigDir as NSString).isAbsolutePath {
            configRoot = URL(fileURLWithPath: expandedConfigDir, isDirectory: true)
        } else {
            configRoot = URL(
                fileURLWithPath: NSString(string: home).expandingTildeInPath,
                isDirectory: true
            )
            .appendingPathComponent(configDir, isDirectory: true)
        }
        return configRoot.appendingPathComponent("agent", isDirectory: true)
    }

    private static func nonEmptyEnvironmentValue(_ name: String, in environment: [String: String]) -> String? {
        let trimmed = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func ompExtensionURL() -> URL {
        return Self.resolvedOmpAgentDirectory()
            .appendingPathComponent("extensions", isDirectory: true)
            .appendingPathComponent(Self.ompExtensionFilename, isDirectory: false)
    }

    private func existingOmpExtensionContents(at url: URL, fileManager: FileManager = .default) throws -> String {
        guard fileManager.fileExists(atPath: url.path) else { return "" }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            let message = String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.omp.error.readFailed",
                    defaultValue: "Failed to read %@"
                ),
                url.path
            )
            throw CLIError(message: "\(message): \(String(describing: error))")
        }
    }

    func installOmpExtensionHooks(_ _: AgentHookDef) throws {
        let extensionURL = ompExtensionURL()
        let fileManager = FileManager.default
        let skipConfirm = ProcessInfo.processInfo.arguments.contains("--yes")
            || ProcessInfo.processInfo.arguments.contains("-y")
        let existing = try existingOmpExtensionContents(at: extensionURL, fileManager: fileManager)
        if existing == Self.ompExtensionSource {
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.omp.alreadyUpToDate",
                    defaultValue: "OMP hooks already up to date at %@"
                ),
                extensionURL.path
            ))
            return
        }
        if !existing.isEmpty, !existing.contains(Self.ompExtensionMarker) {
            throw CLIError(message: String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.omp.error.notCmuxExtension",
                    defaultValue: "%@ exists and is not a cmux extension; leaving it alone"
                ),
                extensionURL.path
            ))
        }
        if !skipConfirm {
            Self.printInstallPreview(
                path: extensionURL.path,
                oldContent: existing,
                newContent: Self.ompExtensionSource,
                fallbackContent: Self.ompExtensionSource
            )
            print(String(localized: "cli.hooks.omp.confirmProceed", defaultValue: "\nProceed? [y/N] "), terminator: "")
            guard readLine()?.lowercased().hasPrefix("y") == true else {
                print(String(localized: "cli.hooks.omp.aborted", defaultValue: "Aborted."))
                return
            }
        }
        try fileManager.createDirectory(
            at: extensionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.ompExtensionSource.write(to: extensionURL, atomically: true, encoding: .utf8)
        print(String.localizedStringWithFormat(
            String(
                localized: "cli.hooks.omp.installed",
                defaultValue: "OMP hooks installed at %@"
            ),
            extensionURL.path
        ))
    }

    func uninstallOmpExtensionHooks(_ _: AgentHookDef) throws {
        let extensionURL = ompExtensionURL()
        let fm = FileManager.default
        guard fm.fileExists(atPath: extensionURL.path) else {
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.omp.noneFound",
                    defaultValue: "No OMP cmux extension found at %@"
                ),
                extensionURL.path
            ))
            return
        }
        let existing = try existingOmpExtensionContents(at: extensionURL, fileManager: fm)
        guard existing.contains(Self.ompExtensionMarker) else {
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.omp.refuseRemoveMissingMarker",
                    defaultValue: "Refusing to remove %@: missing cmux marker"
                ),
                extensionURL.path
            ))
            return
        }
        try fm.removeItem(at: extensionURL)
        print(String.localizedStringWithFormat(
            String(
                localized: "cli.hooks.omp.removed",
                defaultValue: "Removed OMP cmux extension from %@"
            ),
            extensionURL.path
        ))
    }
}
