extension CMUXCLI {
    static let ampExtensionPrelude = #"""
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
    const child = spawn(cmuxBin(), ["hooks", "amp", subcommand], {
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
  idle: { label: "idle", icon: "circle", color: COLOR.idle },
  thinking: { label: "thinking", icon: "brain", color: COLOR.thinking },
  needsInput: { label: "needs input", icon: "bell.fill", color: COLOR.needsInput },
  done: { label: "done", icon: "checkmark.circle", color: COLOR.done },
  error: { label: "error", icon: "xmark.circle", color: COLOR.error },
  interrupted: { label: "interrupted", icon: "pause.circle", color: COLOR.interrupted },
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

"""#
}
