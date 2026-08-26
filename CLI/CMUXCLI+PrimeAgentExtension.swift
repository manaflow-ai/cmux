import Foundation

extension CMUXCLI {
    static let primeAgentExtensionMarker = "cmux-prime-agent-session-extension-marker"
    static let primeAgentExtensionFilename = "cmux-prime-agent-session.ts"
    static let primeAgentExtensionSource = #"""
// cmux-prime-agent-session-extension-marker v1
// Bridges Prime Agent session lifecycle events into cmux's managed resume store.
// Installed by `cmux hooks prime-agent install` or `cmux hooks setup`.
// DO NOT EDIT MANUALLY. cmux upgrades this file in place.
// The managed binding is equivalent to `prime-agent --resume <absolute-session-file>`.

import { Buffer } from "node:buffer";
import { spawn } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

type RootSession = { sessionId: string; sessionFile: string; cwd: string; surfaceId: string };
type PrimeOwner = { sessionId: string; surfaceId: string; instanceId: string };
type PrimeGlobalState = { owners: Map<string, PrimeOwner> };

function firstString(...values: unknown[]): string | null {
  for (const value of values) {
    if (typeof value === "string" && value.trim().length > 0) return value.trim();
  }
  return null;
}

function bounded(value: string | undefined, limit = 32768): string | undefined {
  if (value === undefined || value.length <= limit) return value;
  return value.slice(0, limit);
}

function isHeadlessInvocation(): boolean {
  const args = Array.isArray(process.argv) ? process.argv.map((value) => String(value)) : [];
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === "--") break;
    if (arg === "-p" || arg === "--print" || arg.startsWith("-p=") || arg.startsWith("--print=")
      || arg === "--json" || arg.startsWith("--json=")
      || arg === "--rpc" || arg.startsWith("--rpc=")
      || arg === "--acp" || arg.startsWith("--acp=")
      || arg === "--daemon" || arg.startsWith("--daemon=")) {
      return true;
    }
    if (arg === "--mode") return true;
    if (arg.startsWith("--mode=")) return true;
  }
  return false;
}

function rootSession(ctx: ExtensionContext): RootSession | null {
  if (process.env.CMUX_PRIME_AGENT_HOOKS_DISABLED === "1") return null;
  if (ctx.hasUI !== true) return null;
  if (isHeadlessInvocation()) return null;
  const surfaceId = firstString(process.env.CMUX_SURFACE_ID);
  if (!surfaceId) return null;
  const rawDepth = firstString(process.env.RLM_DEPTH);
  const depth = Number.parseInt(rawDepth || "0", 10);
  if (Number.isFinite(depth) && depth > 0) return null;
  // Older Prime builds did not export RLM_DEPTH consistently, but RLM
  // children still receive their private session directory. Treat that
  // combination as a child while allowing a normal root with RLM_DEPTH=0.
  if ((!rawDepth || !Number.isFinite(depth)) && firstString(process.env.RLM_SESSION_DIR)) return null;
  const sessionId = firstString(ctx.sessionManager.getSessionId());
  const rawSessionFile = firstString(ctx.sessionManager.getSessionFile());
  if (!sessionId || !rawSessionFile || !path.isAbsolute(rawSessionFile)
    || rawSessionFile.endsWith(path.sep)) return null;
  const sessionFile = path.normalize(rawSessionFile);
  if (sessionFile === path.parse(sessionFile).root) return null;
  return {
    sessionId,
    sessionFile,
    cwd: firstString(ctx.cwd, process.cwd()) || process.cwd(),
    surfaceId,
  };
}

function globalState(): PrimeGlobalState {
  const holder = globalThis as typeof globalThis & { __cmuxPrimeAgentState?: PrimeGlobalState };
  if (!holder.__cmuxPrimeAgentState || !(holder.__cmuxPrimeAgentState.owners instanceof Map)) {
    holder.__cmuxPrimeAgentState = { owners: new Map() };
  }
  return holder.__cmuxPrimeAgentState;
}

function rootKey(root: RootSession): string {
  return `${root.surfaceId}\u0000${root.sessionId}`;
}

function claimRoot(root: RootSession, instanceId: string): boolean {
  const state = globalState();
  // A surface can have only one visible Prime session. Key ownership by the
  // surface (rather than surface + session) so an RLM/child session that
  // leaks CMUX_SURFACE_ID cannot replace the root even if an older Prime
  // build omitted its RLM markers. Session-specific queues still use
  // rootKey(), because a real session replacement is released on shutdown
  // before the replacement session_start event.
  const owner = state.owners.get(root.surfaceId);
  if (!owner) state.owners.set(root.surfaceId, { sessionId: root.sessionId, surfaceId: root.surfaceId, instanceId });
  return state.owners.get(root.surfaceId)?.instanceId === instanceId
    && state.owners.get(root.surfaceId)?.sessionId === root.sessionId;
}

function releaseRoot(root: RootSession, instanceId: string): void {
  const state = globalState();
  if (state.owners.get(root.surfaceId)?.instanceId === instanceId) state.owners.delete(root.surfaceId);
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

function looksLikePrimeAgentExecutable(value: string): boolean {
  return path.basename(value).toLowerCase() === "prime-agent";
}

function looksLikePrimeAgentScript(value: string): boolean {
  const normalized = value.replaceAll("\\", "/").toLowerCase();
  const base = path.basename(normalized);
  const knownEntrypoint = base === "cli.js" || base === "cli.ts" || base === "index.js" || base === "index.ts";
  const hasPrimePackageMarker = normalized.includes("/.prime/agent/")
    || normalized.includes("/prime-agent/")
    || normalized.includes("/@earendil-works/pi-coding-agent/");
  const hasCodingAgentMarker = normalized.includes("/coding-agent/")
    || normalized.includes("/pi-coding-agent/")
    || knownEntrypoint;
  return hasPrimePackageMarker && hasCodingAgentMarker;
}

function looksLikeJavaScriptRuntime(value: string): boolean {
  const base = path.basename(value).toLowerCase();
  return base === "node" || base === "bun" || base === "deno" || base === "tsx" || base === "ts-node";
}

function primeAgentEntrypointIndex(raw: string[]): number {
  for (let index = 1; index < raw.length; index += 1) {
    if (raw[index] === "--") break;
    if (looksLikePrimeAgentExecutable(raw[index] || "") || looksLikePrimeAgentScript(raw[index] || "")) {
      return index;
    }
  }
  return -1;
}

function normalizedLaunchArgv(): string[] {
  const raw = Array.isArray(process.argv) ? process.argv.map((value) => String(value)) : [];
  if (raw.length === 0) return [resolveExecutable("prime-agent")];
  if (looksLikePrimeAgentExecutable(raw[0])) return raw;
  const entrypointIndex = primeAgentEntrypointIndex(raw);
  if (entrypointIndex >= 0) {
    return [resolveExecutable("prime-agent"), ...raw.slice(entrypointIndex + 1)];
  }
  if (raw.length > 1 && looksLikeJavaScriptRuntime(raw[0])) {
    return [resolveExecutable("prime-agent"), ...raw.slice(1)];
  }
  return [resolveExecutable("prime-agent"), ...raw.slice(1)];
}

function base64NulSeparated(values: string[]): string {
  const bytes: Buffer[] = [];
  for (const value of values) {
    bytes.push(Buffer.from(String(value), "utf8"));
    bytes.push(Buffer.from([0]));
  }
  return Buffer.concat(bytes).toString("base64");
}

function launchEnvironment(cwd: string): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = { ...process.env };
  // The extension runs in the visible Prime process, so its normalized argv
  // is the authoritative capture. Descendants can inherit a same-kind
  // CMUX_AGENT_LAUNCH_* tuple from an older Prime session; preserving it would
  // silently replay the wrong model/options after a relaunch.
  const argv = normalizedLaunchArgv();
  const executable = argv[0] || resolveExecutable("prime-agent");
  env.CMUX_AGENT_LAUNCH_KIND = "prime-agent";
  env.CMUX_AGENT_LAUNCH_EXECUTABLE = executable;
  env.CMUX_AGENT_LAUNCH_ARGV_B64 = base64NulSeparated(argv);
  env.CMUX_AGENT_LAUNCH_CWD = cwd;
  return env;
}

function assistantText(event: unknown): string | undefined {
  if (!event || typeof event !== "object") return undefined;
  const messages = (event as { messages?: unknown }).messages;
  if (!Array.isArray(messages)) return undefined;
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index];
    if (!message || typeof message !== "object") continue;
    const typed = message as { role?: unknown; content?: unknown };
    if (typed.role !== "assistant") continue;
    if (typeof typed.content === "string") return bounded(typed.content);
    if (!Array.isArray(typed.content)) continue;
    const text = typed.content
      .filter((part): part is { text: string } => Boolean(part && typeof part === "object" && typeof (part as { text?: unknown }).text === "string"))
      .map((part) => part.text)
      .join("\n");
    if (text) return bounded(text);
  }
  return undefined;
}

interface QueuedHook {
  root: RootSession;
  subcommand: string;
  extra: Record<string, unknown>;
}

interface RunningHook {
  completion: Promise<void>;
  cancel: () => void;
}

interface HookQueue {
  items: QueuedHook[];
  worker: Promise<void> | null;
  active: RunningHook | null;
  activeSubcommand: string | null;
}

interface SessionLifecycleState {
  stopped: boolean;
}

const maxQueuedHooks = 32;
const hookShutdownDeadlineMs = 2000;

function startHook(invocation: QueuedHook): RunningHook {
  const cmux = process.env.CMUX_PRIME_AGENT_CMUX_BIN || process.env.CMUX_BUNDLED_CLI_PATH || "cmux";
  const payload = JSON.stringify({
    session_id: invocation.root.sessionId,
    session_file: invocation.root.sessionFile,
    transcript_path: invocation.root.sessionFile,
    cwd: invocation.root.cwd,
    hook_event_name: invocation.subcommand,
    event: invocation.subcommand,
    ...invocation.extra,
  });
  let child: ReturnType<typeof spawn> | null = null;
  let settle = () => {};
  let settled = false;
  const timeout = setTimeout(() => {
    if (child && !child.killed) child.kill("SIGKILL");
    settle();
  }, 5000);
  timeout.unref();
  const completion = new Promise<void>((resolve) => {
    settle = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      resolve();
    };
    try {
      child = spawn(cmux, ["hooks", "prime-agent", invocation.subcommand], {
        env: launchEnvironment(invocation.root.cwd),
        stdio: ["pipe", "ignore", "ignore"],
      });
      child.on("error", settle);
      child.on("close", settle);
      child.stdin.on("error", () => {});
      child.stdin.end(payload);
    } catch (_) {
      settle();
    }
  });
  return {
    completion,
    cancel: () => {
      if (child && !child.killed) child.kill("SIGKILL");
      settle();
    },
  };
}

function hookPriority(subcommand: string): number {
  switch (subcommand) {
    case "stop": return 2;
    case "session-start": return 1;
    default: return 0;
  }
}

function createHookQueue(): {
  get: (key: string) => HookQueue;
  remove: (key: string) => void;
} {
  const queues = new Map<string, HookQueue>();
  return {
    get(key) {
      let queue = queues.get(key);
      if (!queue) {
        queue = { items: [], worker: null, active: null, activeSubcommand: null };
        queues.set(key, queue);
      }
      return queue;
    },
    remove(key) {
      queues.delete(key);
    },
  };
}

async function drainHookQueue(queue: HookQueue): Promise<void> {
  while (queue.items.length > 0) {
    const next = queue.items.shift();
    if (!next) continue;
    const running = startHook(next);
    queue.active = running;
    queue.activeSubcommand = next.subcommand;
    await running.completion;
    if (queue.active === running) {
      queue.active = null;
      queue.activeSubcommand = null;
    }
  }
}

function startHookWorker(queue: HookQueue): void {
  if (queue.worker) return;
  const worker = drainHookQueue(queue).catch(() => undefined);
  queue.worker = worker;
  void worker.finally(() => {
    if (queue.worker === worker) queue.worker = null;
    if (queue.items.length > 0) startHookWorker(queue);
  });
}

async function waitForHookWorker(worker: Promise<void>, timeoutMs: number): Promise<boolean> {
  let completed = false;
  let timeout: ReturnType<typeof setTimeout> | null = null;
  await Promise.race([
    worker.then(() => { completed = true; }),
    new Promise<void>((resolve) => { timeout = setTimeout(resolve, timeoutMs); }),
  ]);
  if (timeout) clearTimeout(timeout);
  return completed;
}

async function awaitHookQueueDrain(queue: HookQueue): Promise<void> {
  // Prompt submissions are useful while the agent is alive but should never
  // delay the final stop event during process teardown.
  queue.items = queue.items.filter((item) => item.subcommand !== "prompt-submit");
  const worker = queue.worker;
  if (!worker) return;
  if (await waitForHookWorker(worker, hookShutdownDeadlineMs)) return;

  queue.items = queue.items.filter((item) => item.subcommand === "stop");
  if (queue.activeSubcommand !== "stop") queue.active?.cancel();
  if (await waitForHookWorker(worker, hookShutdownDeadlineMs)) return;

  queue.items = [];
  queue.active?.cancel();
  await worker;
}

function enqueueHook(
  queue: HookQueue,
  root: RootSession,
  subcommand: string,
  extra: Record<string, unknown>,
): void {
  const duplicate = queue.items.findIndex((item) => item.subcommand === subcommand);
  if (duplicate >= 0) queue.items.splice(duplicate, 1);
  if (queue.items.length >= maxQueuedHooks) {
    const evictable = queue.items.findIndex((item) => hookPriority(item.subcommand) < hookPriority(subcommand));
    if (evictable >= 0) queue.items.splice(evictable, 1);
    else return;
  }
  queue.items.push({ root, subcommand, extra });
  startHookWorker(queue);
}

export default function cmuxPrimeAgentSessionExtension(api: ExtensionAPI) {
  const queues = createHookQueue();
  const lifecycleStates = new Map<string, SessionLifecycleState>();
  const instanceId = `${process.pid}:${Date.now()}:${Math.random().toString(36).slice(2)}`;

  api.on("session_start", (event, ctx) => {
    const root = rootSession(ctx);
    if (!root || !claimRoot(root, instanceId)) return;
    const key = rootKey(root);
    // Prime emits session_start again when it reloads extensions. The generic
    // cmux hook treats session-start as a running transition, so forwarding a
    // reload would turn an already-idle surface back to running without a new
    // turn. The existing session record is durable; the next prompt/agent_end
    // continues to update it normally.
    if (event && typeof event === "object" && (event as { reason?: unknown }).reason === "reload") {
      // Keep an existing state when this callback is delivered by the same
      // extension instance. A freshly loaded module intentionally does not
      // manufacture a running state: the old instance already handled its
      // reload shutdown, and a synthetic state would emit a duplicate stop
      // when Prime later quits without another prompt.
      return;
    }
    lifecycleStates.set(key, { stopped: false });
    enqueueHook(queues.get(key), root, "session-start", {});
  });

  api.on("before_agent_start", (event, ctx) => {
    const root = rootSession(ctx);
    if (!root || !claimRoot(root, instanceId)) return;
    const key = rootKey(root);
    const state = lifecycleStates.get(key) || { stopped: false };
    state.stopped = false;
    lifecycleStates.set(key, state);
    enqueueHook(queues.get(key), root, "prompt-submit", {
      prompt: bounded(event.prompt, 32768),
    });
  });

  api.on("agent_end", (event, ctx) => {
    const root = rootSession(ctx);
    if (!root || !claimRoot(root, instanceId)) return;
    const key = rootKey(root);
    lifecycleStates.set(key, { stopped: true });
    enqueueHook(queues.get(key), root, "stop", {
      last_assistant_message: assistantText(event),
    });
  });

  api.on("session_shutdown", async (event, ctx) => {
    const root = rootSession(ctx);
    if (!root) return;
    const key = rootKey(root);
    // A second copy of the extension can observe the same lifecycle event
    // when Prime reloads extensions. Only the instance that accepted this
    // session_start may drain and release the surface; otherwise a late
    // duplicate could claim the just-released surface and emit a second stop.
    if (!lifecycleStates.has(key) || !claimRoot(root, instanceId)) return;
    const state = lifecycleStates.get(key) || { stopped: false };
    const reason = event && typeof event === "object"
      ? firstString((event as { reason?: unknown }).reason)
      : null;
    if (!state.stopped) {
      enqueueHook(queues.get(key), root, "stop", {
        terminationReason: reason || "session_shutdown",
      });
    }
    await awaitHookQueueDrain(queues.get(key));
    lifecycleStates.delete(key);
    queues.remove(key);
    releaseRoot(root, instanceId);
  });
}
"""#

}
