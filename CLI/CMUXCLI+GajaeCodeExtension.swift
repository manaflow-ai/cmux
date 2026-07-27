import Foundation

extension CMUXCLI {
    private static let gajaeCodeExtensionMarker = "cmux-gajae-code-session-extension-marker"
    private static let gajaeCodeExtensionFilename = "cmux-gajae-code-session.ts"
    private static let gajaeCodeExtensionSource = #"""
// cmux-gajae-code-session-extension-marker v1
// Bridges Gajae Code session lifecycle events into cmux's restorable session store.
// Installed by `cmux hooks gajae-code install` or `cmux hooks setup`.
// DO NOT EDIT MANUALLY. cmux upgrades this file in place.

import { spawn } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import type { AgentEndEvent, ExtensionAPI, ExtensionContext } from "@gajae-code/coding-agent";

let activeSessionId: string | null = null;

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

function looksLikeGajaeCodeExecutable(value: string): boolean {
  const base = path.basename(value).toLowerCase();
  return base === "gjc" || base === "gjc.exe";
}

function looksLikeGajaeCodeScript(value: string): boolean {
  const normalized = value.replaceAll("\\", "/").toLowerCase();
  const base = path.basename(normalized);
  return (
    normalized.includes("/@gajae-code/coding-agent/") ||
    normalized.includes("/gajae-code/packages/coding-agent/") ||
    (base === "gjc.js" && normalized.includes("/gajae-code/"))
  );
}

function looksLikeJavaScriptRuntime(value: string): boolean {
  const base = path.basename(value).toLowerCase();
  return base === "node" || base === "bun" || base === "deno" || base === "tsx" || base === "ts-node";
}

function normalizedLaunchArgv(): string[] {
  const raw = Array.isArray(process.argv) ? process.argv.map((value) => String(value)) : [];
  let argv: string[];
  if (raw.length === 0) {
    argv = [resolveExecutable("gjc")];
  } else if (looksLikeGajaeCodeExecutable(raw[0])) {
    argv = raw;
  } else if (raw.length > 1 && (looksLikeGajaeCodeScript(raw[1]) || looksLikeJavaScriptRuntime(raw[0]))) {
    argv = [resolveExecutable("gjc"), ...raw.slice(2)];
  } else {
    argv = [resolveExecutable("gjc"), ...raw.slice(1)];
  }
  if (firstString(process.env.GJC_TMUX_ACTIVE_SESSION) && !argv.includes("--tmux")) {
    argv.push("--tmux");
  }
  return argv;
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
  const argv = normalizedLaunchArgv();
  // Always replace inherited launch metadata. An agent started from another
  // agent's terminal otherwise inherits the ancestor's resume command.
  env.CMUX_AGENT_LAUNCH_KIND = "gajae-code";
  env.CMUX_AGENT_LAUNCH_EXECUTABLE = argv[0] || resolveExecutable("gjc");
  env.CMUX_AGENT_LAUNCH_ARGV_B64 = base64NulSeparated(argv);
  env.CMUX_AGENT_LAUNCH_CWD = cwd || process.cwd();
  const tmuxSession = firstString(process.env.GJC_TMUX_ACTIVE_SESSION);
  if (tmuxSession) env.GJC_TMUX_SESSION = tmuxSession;
  return env;
}

function isRootSession(ctx: ExtensionContext): boolean {
  if (firstString(process.env.GJC_TEAM_WORKER, process.env.GJC_TEAM_INTERNAL_WORKER)) return false;
  return ctx.sessionMetadata?.kind !== "sub";
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

function hookInvocation(
  subcommand: string,
  ctx: ExtensionContext,
  extra: Record<string, unknown> = {},
): HookInvocation | null {
  if (process.env.CMUX_GAJAE_CODE_HOOKS_DISABLED === "1") return null;
  if (!process.env.CMUX_SURFACE_ID || !isRootSession(ctx)) return null;

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
  const cmux = process.env.CMUX_GAJAE_CODE_CMUX_BIN || "cmux";
  return {
    cmux,
    cwd,
    payload: JSON.stringify(payload),
    env: hookEnvironment(cwd),
  };
}

async function sendHook(
  subcommand: string,
  ctx: ExtensionContext,
  extra: Record<string, unknown> = {},
): Promise<void> {
  const invocation = hookInvocation(subcommand, ctx, extra);
  if (!invocation) return;
  await new Promise<void>((resolve) => {
    let settled = false;
    let timeout: ReturnType<typeof setTimeout> | null = null;
    const settle = () => {
      if (settled) return;
      settled = true;
      if (timeout) clearTimeout(timeout);
      resolve();
    };
    try {
      const child = spawn(invocation.cmux, ["hooks", "gajae-code", subcommand], {
        env: invocation.env,
        stdio: ["pipe", "ignore", "ignore"],
      });
      child.on("error", settle);
      child.stdin.on("error", settle);
      // Session switches must reach cmux in event order so an older session
      // cannot win the surface binding race after a newer one.
      child.on("close", settle);
      timeout = setTimeout(() => {
        try {
          child.kill("SIGTERM");
        } catch (_) {}
        settle();
      }, 5000);
      child.stdin.end(invocation.payload);
    } catch (_) {
      settle();
    }
  });
}

async function bindCurrentSession(ctx: ExtensionContext): Promise<void> {
  if (!isRootSession(ctx)) return;
  const nextSessionId = firstString(ctx.sessionManager.getSessionId());
  if (!nextSessionId) return;
  const previousSessionId = activeSessionId;
  activeSessionId = nextSessionId;
  await sendHook(
    "session-start",
    ctx,
    previousSessionId && previousSessionId !== nextSessionId
      ? { previous_session_id: previousSessionId }
      : {},
  );
}

export default function cmuxGajaeCodeSessionExtension(api: ExtensionAPI) {
  api.on("session_start", async (_event, ctx) => {
    await bindCurrentSession(ctx);
  });

  api.on("session_switch", async (_event, ctx) => {
    await bindCurrentSession(ctx);
  });

  api.on("session_branch", async (_event, ctx) => {
    await bindCurrentSession(ctx);
  });

  api.on("before_agent_start", async (event, ctx) => {
    await sendHook("prompt-submit", ctx, { prompt: event.prompt });
  });

  api.on("agent_end", async (event, ctx) => {
    await sendHook("stop", ctx, { last_assistant_message: lastAssistantMessage(event) });
  });
}
"""#

    static func resolvedGajaeCodeAgentDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath
    ) -> URL {
        if let agentRoot = nonEmptyGajaeCodeEnvironmentValue("GJC_CODING_AGENT_DIR", in: environment) {
            if (agentRoot as NSString).isAbsolutePath {
                return URL(fileURLWithPath: agentRoot, isDirectory: true).standardizedFileURL
            }
            return URL(fileURLWithPath: currentDirectoryPath, isDirectory: true)
                .appendingPathComponent(agentRoot, isDirectory: true)
                .standardizedFileURL
        }

        let home = nonEmptyGajaeCodeEnvironmentValue("HOME", in: environment) ?? NSHomeDirectory()
        let configDir = nonEmptyGajaeCodeEnvironmentValue("GJC_CONFIG_DIR", in: environment) ?? ".gjc"
        let configRoot = (home as NSString).appendingPathComponent(configDir)
        return URL(fileURLWithPath: configRoot, isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .standardizedFileURL
    }

    private static func nonEmptyGajaeCodeEnvironmentValue(
        _ name: String,
        in environment: [String: String]
    ) -> String? {
        let trimmed = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func gajaeCodeExtensionURL() -> URL {
        Self.resolvedGajaeCodeAgentDirectory()
            .appendingPathComponent("extensions", isDirectory: true)
            .appendingPathComponent(Self.gajaeCodeExtensionFilename, isDirectory: false)
    }

    private func existingGajaeCodeExtensionContents(
        at url: URL,
        fileManager: FileManager = .default
    ) throws -> String {
        guard fileManager.fileExists(atPath: url.path) else { return "" }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            let message = String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.gajaeCode.error.readFailed",
                    defaultValue: "Failed to read %@"
                ),
                url.path
            )
            throw CLIError(message: "\(message): \(String(describing: error))")
        }
    }

    func installGajaeCodeExtensionHooks(_ _: AgentHookDef) throws {
        let extensionURL = gajaeCodeExtensionURL()
        let fileManager = FileManager.default
        let skipConfirm = ProcessInfo.processInfo.arguments.contains("--yes")
            || ProcessInfo.processInfo.arguments.contains("-y")
        let existing = try existingGajaeCodeExtensionContents(at: extensionURL, fileManager: fileManager)
        if existing == Self.gajaeCodeExtensionSource {
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.gajaeCode.alreadyUpToDate",
                    defaultValue: "Gajae Code hooks already up to date at %@"
                ),
                extensionURL.path
            ))
            return
        }
        if !existing.isEmpty, !existing.contains(Self.gajaeCodeExtensionMarker) {
            throw CLIError(message: String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.gajaeCode.error.notCmuxExtension",
                    defaultValue: "%@ exists and is not a cmux extension; leaving it alone"
                ),
                extensionURL.path
            ))
        }
        if !skipConfirm {
            Self.printInstallPreview(
                path: extensionURL.path,
                oldContent: existing,
                newContent: Self.gajaeCodeExtensionSource,
                fallbackContent: Self.gajaeCodeExtensionSource
            )
            print(
                String(
                    localized: "cli.hooks.gajaeCode.confirmProceed",
                    defaultValue: "\nProceed? [y/N] "
                ),
                terminator: ""
            )
            guard readLine()?.lowercased().hasPrefix("y") == true else {
                print(String(localized: "cli.hooks.gajaeCode.aborted", defaultValue: "Aborted."))
                return
            }
        }
        try fileManager.createDirectory(
            at: extensionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.gajaeCodeExtensionSource.write(to: extensionURL, atomically: true, encoding: .utf8)
        print(String.localizedStringWithFormat(
            String(
                localized: "cli.hooks.gajaeCode.installed",
                defaultValue: "Gajae Code hooks installed at %@"
            ),
            extensionURL.path
        ))
    }

    func uninstallGajaeCodeExtensionHooks(_ _: AgentHookDef) throws {
        let extensionURL = gajaeCodeExtensionURL()
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: extensionURL.path) else {
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.gajaeCode.noneFound",
                    defaultValue: "No Gajae Code cmux extension found at %@"
                ),
                extensionURL.path
            ))
            return
        }
        let existing = try existingGajaeCodeExtensionContents(at: extensionURL, fileManager: fileManager)
        guard existing.contains(Self.gajaeCodeExtensionMarker) else {
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.gajaeCode.refuseRemoveMissingMarker",
                    defaultValue: "Refusing to remove %@: missing cmux marker"
                ),
                extensionURL.path
            ))
            return
        }
        try fileManager.removeItem(at: extensionURL)
        print(String.localizedStringWithFormat(
            String(
                localized: "cli.hooks.gajaeCode.removed",
                defaultValue: "Removed Gajae Code cmux extension from %@"
            ),
            extensionURL.path
        ))
    }
}
