import CMUXAgentLaunch
import Foundation

extension CMUXCLI {
    private static let ompExtensionMarker = "cmux-omp-session-extension-marker"
    private static let ompExtensionFilename = "cmux-omp-session.ts"
    private static let ompExtensionSource = #"""
// cmux-omp-session-extension-marker v2
// Bridges OMP lifecycle and observational telemetry into cmux.
// Installed by `cmux hooks omp install` or `cmux hooks setup`.
// DO NOT EDIT MANUALLY. cmux upgrades this file in place.

import { spawn } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";

type HookExtra = Record<string, unknown>;
type InvocationClass = "prompt" | "feed" | "lifecycle" | "approval";

interface ContextSnapshot {
  sessionId: string;
  cwd: string;
  transcriptPath?: string;
}

interface CmuxInvocation {
  cmux: string;
  args: string[];
  cwd: string;
  sessionId: string;
  payload: string;
  env: NodeJS.ProcessEnv;
  name: string;
  invocationClass: InvocationClass;
  priority: number;
  dedupeKey?: string;
}

interface QueuedInvocation {
  invocation: CmuxInvocation;
}

interface RunningInvocation {
  completion: Promise<void>;
  cancel: () => void;
}

interface FeedProjectionState {
  remainingNodes: number;
  seen: WeakSet<object>;
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
  const candidate = value.length > maximumBytes ? value.slice(0, maximumBytes) : value;
  const bytes = Buffer.from(candidate, "utf8");
  if (bytes.byteLength <= maximumBytes) return candidate;
  return bytes.subarray(0, maximumBytes).toString("utf8").replace(/\uFFFD+$/u, "");
}

function feedValueSummary(value: unknown): Record<string, unknown> {
  if (value === null) return { kind: "null" };
  if (typeof value === "string") return { kind: "text", length: value.length };
  if (typeof value === "boolean" || typeof value === "number") return { kind: typeof value };
  if (Array.isArray(value)) return { kind: "array", count: value.length };
  if (value && typeof value === "object") {
    try {
      return { kind: "object", key_count: Object.keys(value).length };
    } catch (_) {
      return { kind: "object" };
    }
  }
  return { kind: "undefined" };
}

function projectFeedValue(
  value: unknown,
  state: FeedProjectionState,
  depth = 0,
  preserveText = true,
): unknown {
  if (value === null) return preserveText ? null : feedValueSummary(value);
  if (typeof value === "string") {
    return preserveText ? utf8Prefix(value, 512) : feedValueSummary(value);
  }
  if (typeof value === "boolean") return preserveText ? value : feedValueSummary(value);
  if (typeof value === "number") {
    return preserveText && Number.isFinite(value) ? value : feedValueSummary(value);
  }
  if (typeof value !== "object") return feedValueSummary(value);
  if (depth >= 4 || state.remainingNodes <= 0) return feedValueSummary(value);
  if (state.seen.has(value)) return { kind: "circular" };

  state.remainingNodes -= 1;
  state.seen.add(value);
  try {
    if (Array.isArray(value)) {
      const out: unknown[] = [];
      const retained = Math.min(value.length, 12);
      for (let index = 0; index < retained; index += 1) {
        try {
          out.push(projectFeedValue(value[index], state, depth + 1, preserveText));
        } catch (_) {
          out.push({ kind: "unavailable" });
        }
      }
      if (value.length > retained) out.push({ kind: "omitted", count: value.length - retained });
      return out;
    }

    const out: Record<string, unknown> = {};
    let scanned = 0;
    try {
      for (const key in value as Record<string, unknown>) {
        if (scanned >= 12) {
          out.cmux_truncated = true;
          break;
        }
        scanned += 1;
        if (!Object.prototype.hasOwnProperty.call(value, key)) continue;
        const projectedKey = utf8Prefix(key, 128);
        if (!projectedKey) continue;
        try {
          out[projectedKey] = projectFeedValue(
            (value as Record<string, unknown>)[key],
            state,
            depth + 1,
            preserveText,
          );
        } catch (_) {
          out[projectedKey] = { kind: "unavailable" };
        }
      }
    } catch (_) {
      return feedValueSummary(value);
    }
    return out;
  } finally {
    state.seen.delete(value);
  }
}

function boundedFeedPayload(payload: HookExtra): string {
  const maximumBytes = 12 * 1024;
  const serialized = JSON.stringify(payload);
  if (Buffer.byteLength(serialized, "utf8") <= maximumBytes) return serialized;

  const safe: HookExtra = {};
  for (const key of [
    "session_id",
    "cwd",
    "transcript_path",
    "hook_event_name",
    "event",
    "tool_call_id",
    "tool_name",
    "request_id",
  ] as const) {
    const value = utf8Prefix(payload[key], key === "cwd" || key === "transcript_path" ? 2048 : 256);
    if (value !== undefined) safe[key] = value;
  }
  for (const key of ["is_error", "approved"] as const) {
    if (typeof payload[key] === "boolean") safe[key] = payload[key];
  }
  for (const key of ["tool_input", "tool_result", "compaction"] as const) {
    if (payload[key] !== undefined) safe[key] = feedValueSummary(payload[key]);
  }
  return JSON.stringify(safe);
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

function sessionFile(ctx: ExtensionContext): string | null {
  try {
    return firstString(ctx.sessionManager.getSessionFile());
  } catch (_) {
    return null;
  }
}

function isNestedArtifactSession(transcriptPath: string | null): boolean {
  return transcriptPath !== null && fs.existsSync(`${path.dirname(transcriptPath)}.jsonl`);
}

function snapshotContext(ctx: ExtensionContext): ContextSnapshot | null {
  if (process.env.CMUX_OMP_HOOKS_DISABLED === "1") return null;
  if (!process.env.CMUX_SURFACE_ID) return null;

  const transcriptPath = sessionFile(ctx);
  if (isNestedArtifactSession(transcriptPath)) return null;
  const sessionId = firstString(ctx.sessionManager.getSessionId());
  if (!sessionId) return null;
  const cwd = firstString(ctx.cwd, process.cwd()) || process.cwd();
  return {
    sessionId,
    cwd,
    transcriptPath: transcriptPath || undefined,
  };
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
  const messages = objectValue(event, ["messages"]);
  if (!Array.isArray(messages)) return undefined;
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

function boundedHookText(value: unknown, maximumBytes = 32768): string | undefined {
  return utf8Prefix(value, maximumBytes);
}

function invocationPriority(invocationClass: InvocationClass, name: string): number {
  if (name === "stop" || name === "session-end") return 3;
  if (name === "session-start" || invocationClass === "approval") return 2;
  if (invocationClass === "lifecycle" || invocationClass === "prompt") return 1;
  return 0;
}

function cmuxInvocation(
  args: string[],
  name: string,
  eventName: string,
  ctx: ExtensionContext,
  extra: HookExtra,
  invocationClass: InvocationClass,
  dedupe = false,
  boundFeedPayload = false,
): CmuxInvocation | null {
  const context = snapshotContext(ctx);
  if (!context) return null;
  const payload: HookExtra = {
    session_id: context.sessionId,
    cwd: context.cwd,
    hook_event_name: eventName,
    event: eventName,
  };
  if (context.transcriptPath) payload.transcript_path = context.transcriptPath;
  Object.assign(payload, extra);
  let serialized: string;
  try {
    serialized = boundFeedPayload ? boundedFeedPayload(payload) : JSON.stringify(payload);
  } catch (_) {
    return null;
  }
  return {
    cmux: process.env.CMUX_OMP_CMUX_BIN || "cmux",
    args,
    cwd: context.cwd,
    sessionId: context.sessionId,
    payload: serialized,
    env: hookEnvironment(context.cwd),
    name,
    invocationClass,
    priority: invocationPriority(invocationClass, name),
    dedupeKey: dedupe ? `${context.sessionId}:${invocationClass}:${name}` : undefined,
  };
}

function startInvocation(invocation: CmuxInvocation): RunningInvocation {
  let child: ReturnType<typeof spawn> | null = null;
  let settle = () => {};
  const terminate = () => {
    if (child && !child.killed) child.kill("SIGKILL");
  };
  const completion = new Promise<void>((resolve) => {
    let settled = false;
    const timeout = setTimeout(terminate, 5000);
    timeout.unref();
    settle = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      resolve();
    };
    try {
      child = spawn(invocation.cmux, invocation.args, {
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
  return { completion, cancel: terminate };
}

const maxQueuedInvocations = 16;
const shutdownSoftDeadlineMs = 2000;
const shutdownFinishDeadlineMs = 5500;
const invocationQueue: QueuedInvocation[] = [];
let invocationWorker: Promise<void> | null = null;
let activeInvocation: { command: CmuxInvocation; running: RunningInvocation } | null = null;

async function drainInvocationQueue(): Promise<void> {
  while (invocationQueue.length > 0) {
    const next = invocationQueue.shift();
    if (!next) continue;
    const running = startInvocation(next.invocation);
    activeInvocation = { command: next.invocation, running };
    await running.completion;
    if (activeInvocation?.running === running) activeInvocation = null;
  }
}

function startInvocationWorker(): void {
  if (invocationWorker) return;
  invocationWorker = drainInvocationQueue().finally(() => {
    invocationWorker = null;
    if (invocationQueue.length > 0) startInvocationWorker();
  });
}

function enqueueInvocation(invocation: CmuxInvocation): boolean {
  const duplicate = invocation.dedupeKey
    ? invocationQueue.findIndex((queued) => queued.invocation.dedupeKey === invocation.dedupeKey)
    : -1;
  if (duplicate >= 0) {
    invocationQueue.splice(duplicate, 1);
    invocationQueue.push({ invocation });
  } else {
    if (invocationQueue.length >= maxQueuedInvocations) {
      const evictable = invocationQueue.findIndex(
        (queued) => queued.invocation.priority < invocation.priority
      );
      if (evictable >= 0) invocationQueue.splice(evictable, 1);
      else return false;
    }
    invocationQueue.push({ invocation });
  }
  startInvocationWorker();
  return true;
}

async function waitForInvocationWorker(worker: Promise<void>, timeoutMs: number): Promise<boolean> {
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

async function awaitInvocationQueueDrain(): Promise<void> {
  for (let index = invocationQueue.length - 1; index >= 0; index -= 1) {
    if (invocationQueue[index]?.invocation.invocationClass === "prompt") {
      invocationQueue.splice(index, 1);
    }
  }
  const worker = invocationWorker;
  if (!worker) return;
  if (await waitForInvocationWorker(worker, shutdownSoftDeadlineMs)) return;

  const active = activeInvocation?.command;
  if (
    active &&
    active.invocationClass !== "feed" &&
    active.name !== "stop" &&
    active.name !== "session-end"
  ) {
    activeInvocation?.running.cancel();
  }
  if (await waitForInvocationWorker(worker, shutdownFinishDeadlineMs)) return;

  for (let index = invocationQueue.length - 1; index >= 0; index -= 1) {
    if (invocationQueue[index]?.invocation.name !== "session-end") invocationQueue.splice(index, 1);
  }
  activeInvocation?.running.cancel();
  await worker;
}

function lifecycleInvocation(
  subcommand: string,
  eventName: string,
  ctx: ExtensionContext,
  extra: HookExtra = {},
  invocationClass: InvocationClass = "lifecycle",
  dedupe = false,
): CmuxInvocation | null {
  return cmuxInvocation(
    ["hooks", "omp", subcommand],
    subcommand,
    eventName,
    ctx,
    extra,
    invocationClass,
    dedupe,
  );
}

let feedRequestSequence = 0;

function feedInvocation(
  eventName: string,
  ctx: ExtensionContext,
  extra: HookExtra,
): CmuxInvocation | null {
  feedRequestSequence += 1;
  const requestId = firstString(extra.tool_call_id)
    || `omp-${process.pid}-${feedRequestSequence}`;
  return cmuxInvocation(
    ["hooks", "feed", "--source", "omp", "--event", eventName],
    eventName,
    eventName,
    ctx,
    { ...extra, request_id: requestId },
    "feed",
    false,
    true,
  );
}

function enqueueLifecycle(
  subcommand: string,
  eventName: string,
  ctx: ExtensionContext,
  extra: HookExtra = {},
  invocationClass: InvocationClass = "lifecycle",
  dedupe = false,
): string | null {
  const invocation = lifecycleInvocation(
    subcommand,
    eventName,
    ctx,
    extra,
    invocationClass,
    dedupe,
  );
  if (!invocation || !enqueueInvocation(invocation)) return null;
  return invocation.sessionId;
}

function enqueueFeed(eventName: string, ctx: ExtensionContext, extra: HookExtra): void {
  const invocation = feedInvocation(eventName, ctx, extra);
  if (invocation) enqueueInvocation(invocation);
}

function toolEventExtra(event: unknown, terminal: boolean): HookExtra {
  const toolCallId = firstString(objectValue(event, ["toolCallId", "tool_call_id", "id"]));
  const toolName = firstString(objectValue(event, ["toolName", "tool_name", "name"]));
  const projectionState: FeedProjectionState = { remainingNodes: 48, seen: new WeakSet() };
  const extra: HookExtra = {};
  const boundedToolCallId = utf8Prefix(toolCallId, 256);
  if (boundedToolCallId !== undefined) extra.tool_call_id = boundedToolCallId;
  const boundedToolName = utf8Prefix(toolName, 256);
  if (boundedToolName !== undefined) extra.tool_name = boundedToolName;

  if (terminal) {
    const result = objectValue(event, ["result", "details", "content"]);
    if (result !== undefined) {
      extra.tool_result = projectFeedValue(result, projectionState, 0, false);
    }
    const isError = objectValue(event, ["isError", "is_error"]);
    if (typeof isError === "boolean") extra.is_error = isError;
  } else {
    const input = objectValue(event, ["args", "input"]);
    if (input !== undefined) extra.tool_input = projectFeedValue(input, projectionState);
  }
  return extra;
}

function compactEventExtra(event: unknown, before: boolean): HookExtra {
  const compaction: HookExtra = { phase: before ? "before" : "after" };
  if (before) {
    const preparation = objectValue(event, ["preparation"]);
    const tokensBefore = objectValue(preparation, ["tokensBefore", "tokens_before"]);
    if (typeof tokensBefore === "number" && Number.isFinite(tokensBefore)) {
      compaction.tokens_before = tokensBefore;
    }
  } else {
    const fromExtension = objectValue(event, ["fromExtension", "from_extension"]);
    if (typeof fromExtension === "boolean") compaction.from_extension = fromExtension;
    const entry = objectValue(event, ["compactionEntry", "compaction_entry"]);
    const summary = objectValue(entry, ["summary"]);
    if (typeof summary === "string") compaction.summary_length = summary.length;
  }
  return { compaction };
}

function isLowercaseTask(event: unknown): boolean {
  return firstString(objectValue(event, ["toolName", "tool_name", "name"])) === "task";
}

export default function cmuxOmpSessionExtension(api: ExtensionAPI) {
  const terminalSessions = new Set<string>();

  const startOrRebindSession = (ctx: ExtensionContext) => {
    const invocation = lifecycleInvocation(
      "session-start",
      "SessionStart",
      ctx,
      {},
      "lifecycle",
      true,
    );
    if (!invocation) return;
    terminalSessions.delete(invocation.sessionId);
    enqueueInvocation(invocation);
  };

  api.on("session_start", async (_event, ctx) => {
    startOrRebindSession(ctx);
  });

  api.on("session_switch", async (_event, ctx) => {
    startOrRebindSession(ctx);
  });

  api.on("session_branch", async (_event, ctx) => {
    startOrRebindSession(ctx);
  });

  api.on("before_agent_start", async (event, ctx) => {
    const invocation = lifecycleInvocation(
      "prompt-submit",
      "UserPromptSubmit",
      ctx,
      { prompt: boundedHookText(objectValue(event, ["prompt"])) },
      "prompt",
      true,
    );
    if (!invocation) return;
    terminalSessions.delete(invocation.sessionId);
    enqueueInvocation(invocation);
  });

  api.on("tool_execution_start", async (event, ctx) => {
    enqueueFeed(
      isLowercaseTask(event) ? "SubagentStart" : "PreToolUse",
      ctx,
      toolEventExtra(event, false),
    );
  });

  api.on("tool_execution_end", async (event, ctx) => {
    enqueueFeed(
      isLowercaseTask(event) ? "SubagentStop" : "PostToolUse",
      ctx,
      toolEventExtra(event, true),
    );
  });

  api.on("session_before_compact", async (event, ctx) => {
    enqueueFeed("PreCompact", ctx, compactEventExtra(event, true));
  });

  api.on("session_compact", async (event, ctx) => {
    enqueueFeed("PostCompact", ctx, compactEventExtra(event, false));
  });

  api.on("tool_approval_requested", async (event, ctx) => {
    const toolCallId = boundedHookText(
      objectValue(event, ["toolCallId", "tool_call_id", "id"]),
      256,
    );
    const toolName = boundedHookText(
      objectValue(event, ["toolName", "tool_name", "name"]),
      256,
    );
    const reason = boundedHookText(objectValue(event, ["reason"]), 1024);
    enqueueLifecycle(
      "notification",
      "Notification",
      ctx,
      {
        event: "permission_request",
        notification_type: "permission_request",
        message: reason ?? toolName,
        tool_call_id: toolCallId,
        tool_name: toolName,
        reason,
        approval_mode: boundedHookText(objectValue(event, ["approvalMode", "approval_mode"]), 64),
        request_id: toolCallId,
      },
      "approval",
    );
  });

  api.on("tool_approval_resolved", async (event, ctx) => {
    const toolCallId = boundedHookText(
      objectValue(event, ["toolCallId", "tool_call_id", "id"]),
      256,
    );
    enqueueLifecycle(
      "approval-response",
      "ApprovalResponse",
      ctx,
      {
        tool_call_id: toolCallId,
        tool_name: boundedHookText(objectValue(event, ["toolName", "tool_name", "name"]), 256),
        approved: objectValue(event, ["approved"]),
        reason: boundedHookText(objectValue(event, ["reason"]), 1024),
        request_id: toolCallId,
      },
      "approval",
    );
  });

  api.on("agent_end", async (event, ctx) => {
    if (objectValue(event, ["willContinue", "will_continue"]) === true) return;
    const invocation = lifecycleInvocation(
      "stop",
      "Stop",
      ctx,
      { last_assistant_message: boundedHookText(lastAssistantMessage(event)) },
    );
    if (!invocation || terminalSessions.has(invocation.sessionId)) return;
    terminalSessions.add(invocation.sessionId);
    if (!enqueueInvocation(invocation)) terminalSessions.delete(invocation.sessionId);
  });

  api.on("session_stop" as any, async () => {
    // OMP may stop an internal run before continuing the same session.
    // Only a terminal agent_end owns the durable Stop transition.
  });

  api.on("session_shutdown", async (_event, ctx) => {
    enqueueLifecycle("session-end", "SessionEnd", ctx);
    await awaitInvocationQueueDrain();
  });
}
"""#

    private static func resolvedOmpHomeDirectory(
        environment: [String: String],
        homeDirectory: String?
    ) -> String {
        let environmentHome = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 }
        return homeDirectory.flatMap { $0.isEmpty ? nil : $0 }
            ?? environmentHome
            ?? NSHomeDirectory()
    }

    private static func requiredOmpAgentDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String? = nil,
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) throws -> URL {
        let home = resolvedOmpHomeDirectory(
            environment: environment,
            homeDirectory: homeDirectory
        )
        let resolver = OmpDirectoryResolver()
        do {
            let resolution = try resolver.resolve(
                arguments: ["omp"],
                environment: environment,
                homeDirectory: home,
                currentDirectory: currentDirectory
            )
            return URL(fileURLWithPath: resolution.agentDirectory, isDirectory: true)
        } catch {
            var defaultEnvironment = environment
            defaultEnvironment.removeValue(forKey: "OMP_PROFILE")
            defaultEnvironment.removeValue(forKey: "PI_PROFILE")
            let fallback = try resolver.resolve(
                arguments: ["omp"],
                environment: defaultEnvironment,
                homeDirectory: home,
                currentDirectory: currentDirectory
            )
            return URL(fileURLWithPath: fallback.agentDirectory, isDirectory: true)
        }
    }

    static func resolvedOmpAgentDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String? = nil,
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) -> URL {
        if let resolved = try? requiredOmpAgentDirectory(
            environment: environment,
            homeDirectory: homeDirectory,
            currentDirectory: currentDirectory
        ) {
            return resolved
        }
        let home = resolvedOmpHomeDirectory(
            environment: environment,
            homeDirectory: homeDirectory
        )
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".omp/agent", isDirectory: true)
    }

    private func ompExtensionURL(for def: AgentHookDef) throws -> URL {
        try Self.requiredOmpAgentDirectory()
            .appendingPathComponent(def.configFile, isDirectory: false)
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

    func installOmpExtensionHooks(_ def: AgentHookDef) throws {
        let extensionURL = try ompExtensionURL(for: def)
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

    func uninstallOmpExtensionHooks(_ def: AgentHookDef) throws {
        let extensionURL = try ompExtensionURL(for: def)
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
