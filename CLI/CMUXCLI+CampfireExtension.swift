import Foundation

extension CMUXCLI {
    static let campfireExtensionMarker = "cmux-campfire-session-extension-marker"
    static let campfireExtensionFilename = "cmux-campfire-session.ts"
    static let campfireExtensionSource = #"""
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
const OBSERVER_MAX_IN_FLIGHT = 8;
const OBSERVER_MAX_PENDING = 32;

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

function observerDeliveryKey(ctx: ExtensionContext, event: CampfireObserverEvent, payload: Record<string, unknown>): string {
  const sessionId = firstString(ctx.sessionManager.getSessionId()) || "unknown-session";
  const eventType = firstString(payload.campfire_event_type) || event.type || "unknown-event";
  const displayName = firstString(event.displayName) || "";
  const capability = firstString(event.capability) || "";
  return [sessionId, eventType, displayName, capability].join("\u0000");
}

interface ObserverDelivery {
  ctx: ExtensionContext;
  payload: Record<string, unknown>;
}

type Cleanup = () => void;

function cleanupFrom(value: unknown): Cleanup | null {
  return typeof value === "function" ? (value as Cleanup) : null;
}

function registerApiListener(
  api: ExtensionAPI,
  eventName: string,
  handler: (...args: unknown[]) => unknown,
): Cleanup {
  try {
    const registered = (api as unknown as { on: (name: string, handler: (...args: unknown[]) => unknown) => unknown }).on(
      eventName,
      handler,
    );
    return cleanupFrom(registered) || (() => {});
  } catch (_) {
    return () => {};
  }
}

export default function cmuxCampfireSessionExtension(api: ExtensionAPI) {
  let activeContext: ExtensionContext | null = null;
  let disposed = false;
  const cleanupCallbacks: Cleanup[] = [];
  const bridge = observerBridge();
  const inFlightObserverDeliveries = new Set<string>();
  const pendingObserverDeliveries = new Map<string, ObserverDelivery>();

  function enqueueObserverDelivery(key: string, delivery: ObserverDelivery) {
    if (pendingObserverDeliveries.has(key)) {
      pendingObserverDeliveries.set(key, delivery);
      return;
    }
    if (pendingObserverDeliveries.size >= OBSERVER_MAX_PENDING) return;
    pendingObserverDeliveries.set(key, delivery);
  }

  function startObserverDelivery(key: string, delivery: ObserverDelivery) {
    if (disposed) return;
    if (inFlightObserverDeliveries.has(key) || inFlightObserverDeliveries.size >= OBSERVER_MAX_IN_FLIGHT) {
      enqueueObserverDelivery(key, delivery);
      return;
    }
    inFlightObserverDeliveries.add(key);
    void sendHook("notification", delivery.ctx, delivery.payload, { waitForExit: false }).finally(() => {
      inFlightObserverDeliveries.delete(key);
      drainObserverDeliveries();
    });
  }

  function drainObserverDeliveries() {
    if (disposed) return;
    while (inFlightObserverDeliveries.size < OBSERVER_MAX_IN_FLIGHT && pendingObserverDeliveries.size > 0) {
      let entry: [string, ObserverDelivery] | null = null;
      for (const candidate of pendingObserverDeliveries.entries()) {
        if (!inFlightObserverDeliveries.has(candidate[0])) {
          entry = candidate;
          break;
        }
      }
      if (!entry) return;
      const [key, delivery] = entry;
      pendingObserverDeliveries.delete(key);
      startObserverDelivery(key, delivery);
    }
  }

  function cleanup() {
    if (disposed) return;
    disposed = true;
    activeContext = null;
    pendingObserverDeliveries.clear();
    inFlightObserverDeliveries.clear();
    for (const callback of cleanupCallbacks.splice(0).reverse()) {
      try {
        callback();
      } catch (_) {}
    }
  }

  cleanupCallbacks.push(registerApiListener(api, "session_start", async (_event, ctx) => {
    if (disposed) return;
    const context = ctx as ExtensionContext;
    activeContext = context;
    await sendHook("session-start", context);
  }));

  cleanupCallbacks.push(registerApiListener(api, "before_agent_start", async (event, ctx) => {
    if (disposed) return;
    const context = ctx as ExtensionContext;
    activeContext = context;
    const typed = event as { prompt?: unknown };
    await sendHook("prompt-submit", context, { prompt: typed.prompt });
  }));

  cleanupCallbacks.push(registerApiListener(api, "agent_end", async (event, ctx) => {
    if (disposed) return;
    const context = ctx as ExtensionContext;
    activeContext = context;
    await sendHook("stop", context, { last_assistant_message: lastAssistantMessage(event as AgentEndEvent) });
  }));

  cleanupCallbacks.push(registerApiListener(api, "session_end", cleanup));

  const observerListener = (event: CampfireObserverEvent) => {
    const ctx = activeContext;
    if (disposed || !ctx) return;
    const payload = observerPayload(event);
    if (!payload) return;
    const key = observerDeliveryKey(ctx, event, payload);
    startObserverDelivery(key, { ctx, payload });
  };
  bridge.listeners.add(observerListener);
  cleanupCallbacks.push(() => {
    bridge.listeners.delete(observerListener);
  });

  return cleanup;
}
"""#
}
