import Foundation

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

// Prefer the CLI bundled with the cmux app that launched this terminal
// (CMUX_BUNDLED_CLI_PATH) over whatever `cmux` is on PATH, so the plugin always
// talks to the matching app/CLI version — PATH may point at a different build
// (e.g. an installed release while running a dev/tagged app).
// CMUX_AMP_CMUX_BIN takes highest precedence but is test-only plumbing (the
// install test injects a fake cmux binary through it); it isn't set in production.
function cmuxBin(): string {
  return (
    process.env.CMUX_AMP_CMUX_BIN ||
    process.env.CMUX_BUNDLED_CLI_PATH ||
    "cmux"
  );
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
    case "title-update":
      return "TitleUpdate";
    case "stop":
      return "Stop";
    default:
      return subcommand;
  }
}

function sendHook(
  subcommand: string,
  sessionId: string,
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
  const cmux = cmuxBin();
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

type AmpTitleObservable = {
  get?: () => Promise<string | null>;
  subscribe?: (onNext: (value: string | null) => void) => {
    unsubscribe?: () => void;
  };
};

type AmpThreadContext = {
  thread?: { id?: string; title?: AmpTitleObservable };
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
  const cmux = cmuxBin();
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

  // Count of tool calls in flight. While > 0 we display the most recent
  // tool's status; when it returns to 0 we flip back to "thinking".
  let inFlightTools = 0;

  // True between agent.start and agent.end. Used so that a tool.result that
  // arrives after agent.end (cancellation/error races) cannot overwrite the
  // final status badge with "thinking". cmux runs one Amp session per terminal
  // pane, so a single flag is sufficient — concurrent threads would need a
  // per-thread map.
  let turnActive = false;
  let turnEpoch = 0;
  let sessionStartEpoch = 0;

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

  // cmux just stores whatever `title` it receives. Prefer the thread title the
  // user/agent set via the plugin API; fall back to the first user message for
  // Amp versions whose API predates `thread.title`.
  // Cached per thread so we resolve at most once.
  const capturedTitles = new Map<string, string>();
  const TITLE_MAX_LENGTH = 200;
  const TITLE_UPDATE_DEBOUNCE_MS = 250;
  const TITLE_LOOKUP_TIMEOUT_MS = 1000;
  function normalizedTitle(value: unknown): string | null {
    if (typeof value !== "string") return null;
    const title = value
      .slice(0, TITLE_MAX_LENGTH * 2)
      .replace(/\s+/g, " ")
      .trim();
    if (!title) return null;
    return title.length > TITLE_MAX_LENGTH
      ? title.slice(0, TITLE_MAX_LENGTH - 1) + "…"
      : title;
  }

  function titleFromContentBlocks(content: unknown[]): string | null {
    let text = "";
    for (const block of content) {
      if ((block as { type?: string }).type !== "text") continue;
      const raw = (block as { text?: unknown }).text;
      if (typeof raw !== "string") continue;
      const remaining = TITLE_MAX_LENGTH * 2 - text.length;
      if (remaining <= 0) break;
      const piece = raw
        .slice(0, remaining)
        .replace(/\s+/g, " ")
        .trim();
      if (!piece) continue;
      text = text ? `${text} ${piece}` : piece;
      if (text.length >= TITLE_MAX_LENGTH) break;
    }
    return normalizedTitle(text);
  }

  async function resolveSessionTitle(
    threadID: string,
    ctx?: AmpThreadContext,
  ): Promise<string | null> {
    // Always try the real thread title first (cheap, and lets cmux upgrade the
    // stored title once Amp assigns/refines it on a later turn).
    try {
      const threadTitle = normalizedTitle(await ctx?.thread?.title?.get?.());
      if (threadTitle) {
        capturedTitles.set(threadID, threadTitle);
        return threadTitle;
      }
    } catch (_) {}
    const cached = capturedTitles.get(threadID);
    if (cached) return cached;
    try {
      const threads = (
        amp as unknown as {
          experimental?: {
            threads?: {
              get?: (id: string) => {
                messages?: (options?: unknown) => Promise<unknown[]>;
              };
            };
          };
        }
      ).experimental?.threads;
      const handle = threads?.get?.(threadID);
      if (!handle?.messages) return null;
      const messages = await handle.messages({
        from: "start",
        limit: 1,
        roles: ["user"],
      });
      if (!Array.isArray(messages)) return null;
      for (const message of messages) {
        const m = message as { role?: string; content?: unknown };
        if (m.role !== "user" || !Array.isArray(m.content)) continue;
        const title = titleFromContentBlocks(m.content);
        if (title) {
          capturedTitles.set(threadID, title);
          return title;
        }
      }
    } catch (_) {}
    return null;
  }

  function resolveSessionTitleBestEffort(
    threadID: string,
    ctx?: AmpThreadContext,
  ): Promise<string | null> {
    return new Promise((resolve) => {
      const timer = setTimeout(() => resolve(null), TITLE_LOOKUP_TIMEOUT_MS);
      resolveSessionTitle(threadID, ctx)
        .then((title) => resolve(title))
        .catch(() => resolve(null))
        .finally(() => clearTimeout(timer));
    });
  }

  function titleExtra(title: string | null): Record<string, unknown> {
    const normalized = normalizedTitle(title);
    return normalized ? { title: normalized } : {};
  }

  // Amp usually generates the title mid-turn, so reading it on
  // session.start/agent.start misses it. Subscribe once per thread and push each
  // new title to cmux as it lands. Title updates are title-only hook-store
  // writes; they must not replay session-start lifecycle side effects.
  const titleSubs = new Map<string, {
    unsubscribe?: () => void;
    clearTimer?: () => void;
    flushTitle?: () => void;
  }>();
  function flushThreadTitle(threadID: string): void {
    const sub = titleSubs.get(threadID);
    if (!sub) return;
    try {
      sub.flushTitle?.();
    } catch (_) {}
  }

  function cleanupThreadTitle(threadID: string): void {
    const sub = titleSubs.get(threadID);
    if (sub) {
      try {
        sub.clearTimer?.();
      } catch (_) {}
      try {
        sub.unsubscribe?.();
      } catch (_) {}
      titleSubs.delete(threadID);
    }
    capturedTitles.delete(threadID);
  }

  function watchThreadTitle(threadID: string, ctx?: AmpThreadContext): void {
    const observable = ctx?.thread?.title;
    if (!observable?.subscribe || titleSubs.has(threadID)) return;
    let lastSent: string | null = null;
    let pendingTitle: string | null = null;
    let flushTimer: ReturnType<typeof setTimeout> | null = null;
    const flushTitle = () => {
      flushTimer = null;
      const title = pendingTitle;
      pendingTitle = null;
      if (!title || title === lastSent) return;
      lastSent = title;
      capturedTitles.set(threadID, title);
      sendHook("title-update", threadID, cwdFromEnv(), { title });
    };
    const clearTimer = () => {
      if (flushTimer !== null) clearTimeout(flushTimer);
      flushTimer = null;
      pendingTitle = null;
    };
    try {
      const sub = observable.subscribe((value) => {
        const title = normalizedTitle(value);
        if (!title || title === lastSent) return;
        pendingTitle = title;
        capturedTitles.set(threadID, title);
        if (flushTimer !== null) clearTimeout(flushTimer);
        flushTimer = setTimeout(flushTitle, TITLE_UPDATE_DEBOUNCE_MS);
      });
      titleSubs.set(threadID, {
        unsubscribe: () => sub.unsubscribe?.(),
        clearTimer,
        flushTitle,
      });
    } catch (_) {}
  }

  process.on("exit", () => {
    for (const threadID of Array.from(titleSubs.keys())) {
      cleanupThreadTitle(threadID);
    }
  });

  amp.on("session.start", async (event: SessionStartEvent, ctx) => {
    setStatus("idle", "circle", COLOR.idle);
    const sessionId = threadIdFrom(event, ctx);
    if (!sessionId) return;
    const epoch = ++sessionStartEpoch;
    watchThreadTitle(sessionId, ctx);
    sendHook("session-start", sessionId, cwdFromEnv(), titleExtra(capturedTitles.get(sessionId) ?? null));
    void resolveSessionTitleBestEffort(sessionId, ctx).then((title) => {
      if (epoch !== sessionStartEpoch || !title) return;
      sendHook("title-update", sessionId, cwdFromEnv(), { title });
    });
  });

  amp.on("agent.start", async (event: AgentStartEvent, ctx) => {
    inFlightTools = 0;
    turnActive = true;
    const epoch = ++turnEpoch;
    setStatus("thinking", "brain", COLOR.thinking);
    wsLog("prompt received");
    const sessionId = threadIdFrom(event, ctx);
    if (!sessionId) return;
    watchThreadTitle(sessionId, ctx);
    sendHook("prompt-submit", sessionId, cwdFromEnv(), titleExtra(capturedTitles.get(sessionId) ?? null));
    void resolveSessionTitleBestEffort(sessionId, ctx).then((title) => {
      if (!turnActive || epoch !== turnEpoch || !title) return;
      sendHook("title-update", sessionId, cwdFromEnv(), { title });
    });
  });

  amp.on("tool.call", async (event: ToolCallEvent) => {
    inFlightTools++;
    const { label, icon } = detailedToolStatus(event, helpers);
    if (turnActive) {
      setStatus(label, icon, COLOR.active);
    }
    return { action: "allow" as const };
  });

  amp.on("tool.result", async (event: ToolResultEvent) => {
    inFlightTools = Math.max(0, inFlightTools - 1);
    if (event.status === "error") {
      wsLog(`${event.tool} failed`, "error");
    }
    // Skip status updates after agent.end so a lagging tool.result can't
    // overwrite the final badge (done/error/interrupted) with "thinking".
    if (turnActive && inFlightTools === 0) {
      setStatus("thinking", "brain", COLOR.thinking);
    }
  });

  amp.on("agent.end", async (event: AgentEndEvent, ctx) => {
    inFlightTools = 0;
    turnActive = false;
    turnEpoch++;
    sessionStartEpoch++;
    switch (event.status) {
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
        setStatus(String(event.status ?? "done"), "questionmark.circle", COLOR.interrupted);
        wsLog(`turn ended with unexpected status: ${event.status}`, "warning");
        break;
    }
    const sessionId = threadIdFrom(event, ctx);
    if (!sessionId) return;
    sendHook("stop", sessionId, cwdFromEnv());
    flushThreadTitle(sessionId);
    void resolveSessionTitleBestEffort(sessionId, ctx).then((title) => {
      if (title) sendHook("title-update", sessionId, cwdFromEnv(), { title });
    }).finally(() => {
      flushThreadTitle(sessionId);
      cleanupThreadTitle(sessionId);
    });
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
