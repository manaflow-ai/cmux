import Foundation

extension CMUXCLI {
    private static let ompExtensionMarker = "cmux-omp-session-extension-marker"
    private static let ompExtensionFilename = "cmux-omp-session.ts"
    private static let ompExtensionSource = #"""
// cmux-omp-session-extension-marker v1
// Bridges OMP session lifecycle events into cmux's restorable session store.
// Installed by `cmux hooks omp install` or `cmux hooks setup`.
// DO NOT EDIT MANUALLY. cmux upgrades this file in place.

import { spawn } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import type { AgentEndEvent } from "@oh-my-pi/pi-coding-agent/extensibility/shared-events";
import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent/extensibility/extensions/types";

const RESUME_LAUNCH_MARKER = "--cmux-omp-resume-launch";
const EXTENSION_PATH = import.meta.path;
const HOOK_TIMEOUT_MS = 1_500;
const HOOK_FIELD_LIMIT = 4_096;

export type ResumeFallbackDecision = "exit" | "picker";

export function decideResumeFallback(exitCode: number, stderr: string): ResumeFallbackDecision {
  return exitCode !== 0 && /Session "[^"]+" not found\./.test(stderr) ? "picker" : "exit";
}

export function isNestedSessionJournal(sessionFile: string | undefined): boolean {
  if (!sessionFile) return false;
  const parts = path.normalize(sessionFile).split(path.sep);
  const sessionsIndex = parts.lastIndexOf("sessions");
  return sessionsIndex >= 0 && parts.length - sessionsIndex > 3;
}

export function stripSessionSelectorArgs(argv: readonly string[]): string[] {
  const stripped: string[] = [];
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === "--resume" || value === "-r" || value === "--session") {
      const next = argv[index + 1];
      if (next !== undefined && !next.startsWith("-")) index += 1;
      continue;
    }
    stripped.push(value);
  }
  return stripped;
}

export function restorableLaunchArgv(
  launchArgv: readonly string[],
  runtime = process.execPath,
  extensionPath = EXTENSION_PATH,
): string[] {
  const baseArgv = stripSessionSelectorArgs(launchArgv);
  return [runtime, extensionPath, RESUME_LAUNCH_MARKER, base64NulSeparated(baseArgv)];
}

interface ChildResult {
  exitCode: number;
  stderr: string;
}

async function runChild(executable: string, args: string[]): Promise<ChildResult> {
  const child = spawn(executable, args, { stdio: ["inherit", "inherit", "pipe"] });
  const chunks: Buffer[] = [];
  child.stderr.on("data", (chunk: Buffer) => {
    chunks.push(chunk);
    process.stderr.write(chunk);
  });
  const result = Promise.withResolvers<ChildResult>();
  child.on("error", (error) => result.resolve({ exitCode: 1, stderr: error.message }));
  child.on("close", (code) => result.resolve({ exitCode: code ?? 1, stderr: Buffer.concat(chunks).toString("utf8") }));
  return result.promise;
}

function decodeNulSeparated(encoded: string): string[] {
  return Buffer.from(encoded, "base64").toString("utf8").split("\0").filter(Boolean);
}

async function runResumeLaunch(args: string[]): Promise<number> {
  const [encodedLaunchArgv, ...resumeArgs] = args;
  const launchArgv = encodedLaunchArgv ? decodeNulSeparated(encodedLaunchArgv) : [];
  const executable = launchArgv[0];
  if (!executable) {
    process.stderr.write("cmux restore could not determine the OMP executable; starting a new session.\n");
    return (await runChild(resolveExecutable("omp"), [])).exitCode;
  }

  const baseArgs = stripSessionSelectorArgs(launchArgv.slice(1));
  const attempted = await runChild(executable, [...baseArgs, ...resumeArgs]);
  if (decideResumeFallback(attempted.exitCode, attempted.stderr) === "exit") return attempted.exitCode;

  process.stderr.write("\nSaved cmux session is unavailable; opening the OMP session picker instead.\n");
  return (await runChild(executable, [...baseArgs, "--resume"])).exitCode;
}

const resumeLaunchMarkerIndex = process.argv.indexOf(RESUME_LAUNCH_MARKER);
if (resumeLaunchMarkerIndex >= 0) {
  void runResumeLaunch(process.argv.slice(resumeLaunchMarkerIndex + 1)).then(
    (code) => process.exit(code),
    (error: unknown) => {
      process.stderr.write(`cmux OMP restore failed: ${error instanceof Error ? error.message : String(error)}\n`);
      process.exit(1);
    },
  );
}

function firstString(...values: unknown[]): string | null {
  for (const value of values) {
    if (typeof value === "string" && value.trim().length > 0) return value.trim();
  }
  return null;
}

function resolveExecutable(name: string): string {
  if (name === "omp") {
    const home = process.env.HOME || "";
    if (home) {
      const localOmp = path.join(home, ".local", "bin", "omp");
      try {
        fs.accessSync(localOmp, fs.constants.X_OK);
        if (fs.statSync(localOmp).isFile()) return localOmp;
      } catch (_) {}
    }
  }
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

function boundedHookText(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  return value.length > HOOK_FIELD_LIMIT ? `${value.slice(0, HOOK_FIELD_LIMIT)}\n[truncated]` : value;
}

function hookEnvironment(cwd: string): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = { ...process.env };
  const argv = restorableLaunchArgv(normalizedLaunchArgv());
  env.CMUX_AGENT_LAUNCH_KIND = "omp";
  env.CMUX_AGENT_LAUNCH_EXECUTABLE = argv[0] || process.execPath;
  env.CMUX_AGENT_LAUNCH_ARGV_B64 = base64NulSeparated(argv);
  env.CMUX_AGENT_LAUNCH_CWD = cwd || process.cwd();
  env.CMUX_OMP_HOOK_DISPATCH = "1";
  return env;
}

interface HookInvocation {
  cmux: string;
  cwd: string;
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
    case "session-end":
      return "SessionEnd";
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

function hookInvocation(subcommand: string, ctx: ExtensionContext, extra: Record<string, unknown> = {}): HookInvocation | null {
  if (process.env.CMUX_OMP_HOOKS_DISABLED === "1" || process.env.CMUX_OMP_HOOK_DISPATCH === "1") return null;
  if (!process.env.CMUX_SURFACE_ID) return null;
  if (isNestedSessionJournal(ctx.sessionManager.getSessionFile())) return null;

  const sessionId = firstString(ctx.sessionManager.getSessionId());
  if (!sessionId) return null;

  const cwd = firstString(ctx.cwd, process.cwd()) || process.cwd();
  const boundedExtra = Object.fromEntries(
    Object.entries(extra).flatMap(([key, value]) => {
      const bounded = boundedHookText(value);
      return bounded === undefined ? [] : [[key, bounded]];
    }),
  );
  const payload: Record<string, unknown> = {
    session_id: sessionId,
    cwd,
    hook_event_name: eventName(subcommand),
    event: eventName(subcommand),
    ...boundedExtra,
  };
  const cmux = process.env.CMUX_OMP_CMUX_BIN || "cmux";
  return {
    cmux,
    cwd,
    payload: JSON.stringify(payload),
    env: hookEnvironment(cwd),
  };
}

async function sendHook(subcommand: string, ctx: ExtensionContext, extra: Record<string, unknown> = {}): Promise<void> {
  const invocation = hookInvocation(subcommand, ctx, extra);
  if (!invocation) return;
  try {
    const child = spawn(invocation.cmux, ["hooks", "omp", subcommand], {
      env: invocation.env,
      stdio: ["pipe", "ignore", "ignore"],
    });
    let timeout: ReturnType<typeof setTimeout> | undefined;
    let forceKill: ReturnType<typeof setTimeout> | undefined;
    const cleanup = () => {
      if (timeout) clearTimeout(timeout);
      if (forceKill) clearTimeout(forceKill);
      timeout = undefined;
      forceKill = undefined;
    };
    child.on("error", cleanup);
    child.on("close", cleanup);
    child.stdin.on("error", cleanup);
    timeout = setTimeout(() => {
      timeout = undefined;
      if (child.exitCode === null && child.signalCode === null) {
        child.kill("SIGTERM");
        forceKill = setTimeout(() => {
          forceKill = undefined;
          if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
        }, 250);
      }
    }, HOOK_TIMEOUT_MS);
    child.stdin.end(invocation.payload);
  } catch (_) {}
}

export default function cmuxOmpSessionExtension(api: ExtensionAPI) {
  api.on("session_start", async (_event, ctx) => {
    await sendHook("session-start", ctx);
  });

  api.on("before_agent_start", async (event, ctx) => {
    await sendHook("prompt-submit", ctx, { prompt: event.prompt });
  });

  api.on("agent_end", async (event, ctx) => {
    await sendHook("stop", ctx, { last_assistant_message: lastAssistantMessage(event) });
  });

  api.on("session_shutdown", async (_event, ctx) => {
    await sendHook("session-end", ctx);
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
