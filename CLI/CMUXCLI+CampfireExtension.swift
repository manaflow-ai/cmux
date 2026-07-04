import Foundation

extension CMUXCLI {
    private static let campfireExtensionMarker = "cmux-campfire-session-extension-marker"
    private static let campfireExtensionFilename = "cmux-campfire-session.ts"
    private static let campfireExtensionSource = #"""
// cmux-campfire-session-extension-marker v1
// Bridges Campfire session lifecycle events into cmux's restorable session store,
// and Campfire's collaborative moments (join requests, capability asks) into cmux
// notifications. Installed by `cmux hooks campfire install` or `cmux hooks setup`.
// DO NOT EDIT MANUALLY. cmux upgrades this file in place.

import { spawn } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import type { AgentEndEvent, ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

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

function looksLikeBunfsEntry(value: string): boolean {
  // A bun-compiled binary inserts its embedded entrypoint at argv[1] as a
  // virtual path (/$bunfs/root/... or a ~BUN marker). It is not a real file
  // and must never be recorded in a launch command.
  const normalized = value.replaceAll("\\", "/");
  return normalized.includes("$bunfs") || normalized.includes("~BUN") || normalized.includes("%7EBUN");
}

function looksLikeCampfireExecutable(value: string): boolean {
  return path.basename(value).toLowerCase() === "campfire" && !looksLikeBunfsEntry(value);
}

function looksLikeCampfireScript(value: string): boolean {
  const normalized = value.replaceAll("\\", "/").toLowerCase();
  const base = path.basename(normalized);
  return (
    (base === "campfire.ts" || base === "campfire.js" || base === "campfire") &&
    (normalized.includes("/campfire") || normalized.includes("packages/session"))
  );
}

function looksLikeJavaScriptRuntime(value: string): boolean {
  const base = path.basename(value).toLowerCase();
  return base === "node" || base === "bun" || base === "deno" || base === "tsx" || base === "ts-node";
}

function campfireScriptIndex(raw: string[]): number {
  for (let index = 1; index < raw.length; index += 1) {
    if (looksLikeCampfireScript(raw[index] || "")) return index;
  }
  return -1;
}

function normalizedLaunchArgv(): string[] {
  const raw = Array.isArray(process.argv) ? process.argv.map((value) => String(value)) : [];
  if (raw.length === 0) return [resolveExecutable("campfire")];
  if (looksLikeCampfireExecutable(raw[0])) {
    // Compiled binary: drop the bunfs virtual entry at argv[1] when present.
    if (raw.length > 1 && looksLikeBunfsEntry(raw[1])) return [raw[0], ...raw.slice(2)];
    return raw;
  }
  if (raw.length > 1 && looksLikeJavaScriptRuntime(raw[0])) {
    const scriptIndex = campfireScriptIndex(raw);
    if (scriptIndex >= 0) return [resolveExecutable("campfire"), ...raw.slice(scriptIndex + 1)];
  }
  return [resolveExecutable("campfire"), ...raw.slice(1)];
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
  const launchKind = String(env.CMUX_AGENT_LAUNCH_KIND || "").toLowerCase();
  const shouldCaptureLaunch =
    launchKind !== "campfire" ||
    !env.CMUX_AGENT_LAUNCH_EXECUTABLE ||
    !env.CMUX_AGENT_LAUNCH_ARGV_B64 ||
    !env.CMUX_AGENT_LAUNCH_CWD;
  if (shouldCaptureLaunch) {
    const argv = normalizedLaunchArgv();
    env.CMUX_AGENT_LAUNCH_KIND = "campfire";
    env.CMUX_AGENT_LAUNCH_EXECUTABLE = argv[0] || resolveExecutable("campfire");
    env.CMUX_AGENT_LAUNCH_ARGV_B64 = base64NulSeparated(argv);
    env.CMUX_AGENT_LAUNCH_CWD = cwd || process.cwd();
  }
  return env;
}

interface HookInvocation {
  cmux: string;
  cwd: string;
  payload: string;
  env: NodeJS.ProcessEnv;
}

interface SendHookOptions {
  waitForExit?: boolean;
  timeoutMs?: number;
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
  if (process.env.CMUX_CAMPFIRE_HOOKS_DISABLED === "1") return null;
  if (!process.env.CMUX_SURFACE_ID) return null;
  // Newer campfire ships this integration natively (its built-in cmux bridge
  // publishes the flag below). Defer to it so nothing double-fires; this
  // installed file then only serves campfire versions without the native
  // bridge.
  if ((globalThis as Record<symbol, unknown>)[Symbol.for("campfire.cmux.bridge.v1")]) return null;
  // Only the HOST runs the agent and is restorable. A joiner is an ephemeral
  // view whose argv carries the invite URL — a capability token that must
  // never be persisted or replayed — so anything but an explicit host role
  // records nothing.
  if (process.env.CAMPFIRE_SESSION_ROLE !== "host") return null;

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
  const cmux = process.env.CMUX_CAMPFIRE_CMUX_BIN || "cmux";
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
  options: SendHookOptions = {},
): Promise<void> {
  const invocation = hookInvocation(subcommand, ctx, extra);
  if (!invocation) return;
  const waitForExit = options.waitForExit !== false;
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
      const child = spawn(invocation.cmux, ["hooks", "campfire", subcommand], {
        env: invocation.env,
        stdio: ["pipe", "ignore", "ignore"],
        detached: !waitForExit,
      });
      child.on("error", settle);
      child.stdin.on("error", settle);
      if (waitForExit) {
        child.on("close", settle);
        timeout = setTimeout(() => {
          try {
            child.kill("SIGTERM");
          } catch (_) {}
          settle();
        }, options.timeoutMs ?? 5000);
      } else {
        child.stdin.on("finish", settle);
        child.unref();
      }
      child.stdin.end(invocation.payload);
    } catch (_) {
      settle();
    }
  });
}

// Campfire publishes collaborative moments (join requests, capability asks,
// relay health) on a versioned in-process bridge; see campfire's
// docs/observers.md. Payloads are summaries by construction — names, counts,
// capability ids — never prompt text or invite URLs.
interface CampfireObserverEvent {
  type: string;
  displayName?: string;
  capability?: string;
  reason?: string;
}

const OBSERVER_KEY = Symbol.for("campfire.observer.v1");

function observerBridge(): { listeners: Set<(event: CampfireObserverEvent) => void> } {
  const holder = globalThis as Record<symbol, { listeners: Set<(event: CampfireObserverEvent) => void> } | undefined>;
  const existing = holder[OBSERVER_KEY];
  if (existing) return existing;
  const created = { listeners: new Set<(event: CampfireObserverEvent) => void>() };
  holder[OBSERVER_KEY] = created;
  return created;
}

function observerPayload(event: CampfireObserverEvent): Record<string, unknown> | null {
  switch (event.type) {
    case "join.requested":
    case "permission.asked":
    case "relay.error":
      return {
        campfire_event_type: event.type,
        display_name: firstString(event.displayName),
        capability: firstString(event.capability),
      };
    default:
      return null;
  }
}

export default function cmuxCampfireSessionExtension(api: ExtensionAPI) {
  let activeContext: ExtensionContext | null = null;

  api.on("session_start", async (_event, ctx) => {
    activeContext = ctx;
    await sendHook("session-start", ctx);
  });

  api.on("before_agent_start", async (event, ctx) => {
    activeContext = ctx;
    await sendHook("prompt-submit", ctx, { prompt: event.prompt });
  });

  api.on("agent_end", async (event, ctx) => {
    activeContext = ctx;
    await sendHook("stop", ctx, { last_assistant_message: lastAssistantMessage(event) });
  });

  observerBridge().listeners.add((event) => {
    const ctx = activeContext;
    if (!ctx) return;
    const payload = observerPayload(event);
    if (!payload) return;
    void sendHook("notification", ctx, payload, { waitForExit: false });
  });
}
"""#

    static func resolvedCampfireAgentDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let agentRoot = nonEmptyCampfireEnvironmentValue("CAMPFIRE_CODING_AGENT_DIR", in: environment) {
            return URL(
                fileURLWithPath: NSString(string: agentRoot).expandingTildeInPath,
                isDirectory: true
            )
        }

        let home = nonEmptyCampfireEnvironmentValue("HOME", in: environment) ?? NSHomeDirectory()
        return URL(fileURLWithPath: NSString(string: home).expandingTildeInPath, isDirectory: true)
            .appendingPathComponent(".campfire", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
    }

    private static func nonEmptyCampfireEnvironmentValue(_ name: String, in environment: [String: String]) -> String? {
        let trimmed = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func campfireExtensionURL() -> URL {
        return Self.resolvedCampfireAgentDirectory()
            .appendingPathComponent("extensions", isDirectory: true)
            .appendingPathComponent(Self.campfireExtensionFilename, isDirectory: false)
    }

    private func existingCampfireExtensionContents(at url: URL, fileManager: FileManager = .default) throws -> String {
        guard fileManager.fileExists(atPath: url.path) else { return "" }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            let message = String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.campfire.error.readFailed",
                    defaultValue: "Failed to read %@"
                ),
                url.path
            )
            throw CLIError(message: message)
        }
    }

    func installCampfireExtensionHooks(_ _: AgentHookDef) throws {
        let extensionURL = campfireExtensionURL()
        let fileManager = FileManager.default
        let skipConfirm = ProcessInfo.processInfo.arguments.contains("--yes")
            || ProcessInfo.processInfo.arguments.contains("-y")
        let existing = try existingCampfireExtensionContents(at: extensionURL, fileManager: fileManager)
        if existing == Self.campfireExtensionSource {
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.campfire.alreadyUpToDate",
                    defaultValue: "Campfire hooks already up to date at %@"
                ),
                extensionURL.path
            ))
            return
        }
        if !existing.isEmpty, !existing.contains(Self.campfireExtensionMarker) {
            throw CLIError(message: String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.campfire.error.notCmuxExtension",
                    defaultValue: "%@ exists and is not a cmux extension; leaving it alone"
                ),
                extensionURL.path
            ))
        }
        if !skipConfirm {
            Self.printInstallPreview(
                path: extensionURL.path,
                oldContent: existing,
                newContent: Self.campfireExtensionSource,
                fallbackContent: Self.campfireExtensionSource
            )
            print(String(localized: "cli.hooks.campfire.confirmProceed", defaultValue: "\nProceed? [y/N] "), terminator: "")
            guard readLine()?.lowercased().hasPrefix("y") == true else {
                print(String(localized: "cli.hooks.campfire.aborted", defaultValue: "Aborted."))
                return
            }
        }
        try fileManager.createDirectory(
            at: extensionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.campfireExtensionSource.write(to: extensionURL, atomically: true, encoding: .utf8)
        print(String.localizedStringWithFormat(
            String(
                localized: "cli.hooks.campfire.installed",
                defaultValue: "Campfire hooks installed at %@"
            ),
            extensionURL.path
        ))
    }

    func uninstallCampfireExtensionHooks(_ _: AgentHookDef) throws {
        let extensionURL = campfireExtensionURL()
        let fm = FileManager.default
        guard fm.fileExists(atPath: extensionURL.path) else {
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.campfire.noneFound",
                    defaultValue: "No Campfire cmux extension found at %@"
                ),
                extensionURL.path
            ))
            return
        }
        let existing = try existingCampfireExtensionContents(at: extensionURL, fileManager: fm)
        guard existing.contains(Self.campfireExtensionMarker) else {
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.campfire.refuseRemoveMissingMarker",
                    defaultValue: "Refusing to remove %@: missing cmux marker"
                ),
                extensionURL.path
            ))
            return
        }
        try fm.removeItem(at: extensionURL)
        print(String.localizedStringWithFormat(
            String(
                localized: "cli.hooks.campfire.removed",
                defaultValue: "Removed Campfire cmux extension from %@"
            ),
            extensionURL.path
        ))
    }
}
