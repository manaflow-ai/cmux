// cmux-opencode-tui-plugin-marker v2
// OpenCode V2 bridge loaded inside each TUI process.
// The server entry is inert; this module owns the TUI's cmux identity.

import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { createEffect, createRoot } from "solid-js";
import { CMUXFeed } from "./index.js";

const firstString = (...values) => values.find((value) => typeof value === "string" && value.trim())?.trim() || null;
const properties = (event) => event?.data || event?.properties || {};
const statusType = (status) => {
  if (typeof status === "string") return status.trim().toLowerCase();
  if (!status || typeof status !== "object") return null;
  return firstString(status.type, status.status, status.state)?.toLowerCase() || null;
};

function sessionID(event) {
  const data = properties(event);
  const info = data.info || data.message || {};
  const part = data.part || {};
  const permission = data.permission || {};
  const sessionEventID = event?.type?.startsWith("session.") ? info.id : null;
  return firstString(
    data.sessionID,
    data.sessionId,
    data.session_id,
    data.form?.sessionID,
    data.form?.sessionId,
    data.form?.session_id,
    info.sessionID,
    info.sessionId,
    part.sessionID,
    part.sessionId,
    permission.sessionID,
    permission.sessionId,
    sessionEventID,
    event?.sessionID,
    event?.sessionId,
  );
}

function cwd(ctx, event) {
  const data = properties(event);
  return firstString(
    data.info?.directory,
    data.info?.location?.directory,
    data.location?.directory,
    data.directory,
    data.cwd,
    event?.location?.directory,
    ctx?.location?.directory,
    ctx?.directory,
    process.cwd(),
  );
}

function failureMessage(event) {
  const data = properties(event);
  const raw = data.error || data.failure || data.reason;
  if (typeof raw === "string") return raw.slice(0, 500);
  if (raw && typeof raw === "object") {
    const nestedData = raw.data && typeof raw.data === "object" ? raw.data : {};
    const nested = firstString(
      raw.message,
      raw.error,
      raw.reason,
      raw.description,
      nestedData.message,
      nestedData.error,
      nestedData.reason,
      nestedData.description,
      raw.name
    );
    if (nested) return nested.slice(0, 500);
  }
  return firstString(data.message, data.description)?.slice(0, 500) || null;
}

function rootFor(ctx, id) {
  try { return ctx?.data?.session?.root?.(id) || id; } catch (_) { return id; }
}

/** Return true when a session's root is currently visible in this TUI. */
function visibleRoots(ctx) {
  const roots = new Set();
  try {
    const route = ctx?.ui?.router?.current?.() || ctx?.ui?.route?.current;
    const routeID = route?.sessionID || route?.sessionId || route?.params?.sessionID || route?.params?.sessionId;
    if ((route?.type === "session" || route?.name === "session") && routeID) {
      roots.add(rootFor(ctx, routeID));
    }
    if (ctx?.ui?.tabs?.enabled?.() !== false) {
      for (const tab of ctx?.ui?.tabs?.list?.() || []) {
        const idForTab = typeof tab === "string" ? tab : tab?.sessionID || tab?.sessionId || tab?.id;
        if (idForTab) roots.add(rootFor(ctx, idForTab));
      }
    }
  } catch (_) {}
  return roots;
}

/** Return true when a session's root is currently visible in this TUI. */
export function sessionBelongsToTUI(ctx, id) {
  if (!id) return false;
  return visibleRoots(ctx).has(rootFor(ctx, id));
}

function createOwnership(ctx, onChange) {
  let roots = new Set();
  const refreshRoots = () => {
    roots = visibleRoots(ctx);
  };
  const refresh = () => {
    refreshRoots();
    onChange?.();
  };
  refreshRoots();
  const disposers = [];
  for (const owner of [ctx?.ui?.router, ctx?.ui?.tabs]) {
    for (const name of ["onChange", "subscribe", "listen"]) {
      const subscribe = owner?.[name];
      if (typeof subscribe !== "function") continue;
      try {
        const stop = subscribe.call(owner, refresh);
        if (typeof stop === "function") disposers.push(stop);
      } catch (_) {}
      break;
    }
  }
  return {
    // OpenCode v2.0.21 exposes current()/list() but no stable route-change
    // notification. Refresh on the event boundary so a session removed from
    // a background tab, or a closed starter surface, cannot retain ownership.
    belongs: (id) => {
      refreshRoots();
      return Boolean(id && roots.has(rootFor(ctx, id)));
    },
    refresh,
    dispose: () => disposers.forEach((stop) => { try { stop(); } catch (_) {} }),
  };
}

function resolveExecutable(name) {
  for (const directory of (process.env.PATH || "").split(path.delimiter)) {
    if (!directory) continue;
    const candidate = path.join(directory, name);
    try {
      const stat = fs.statSync(candidate);
      if (stat.isFile() && (stat.mode & 0o111)) return candidate;
    } catch (_) {}
  }
  return name;
}

function launchArgv() {
  const raw = Array.isArray(process.argv) ? process.argv.map(String) : [];
  if (raw.length === 0) return [resolveExecutable("opencode")];
  // Compiled OpenCode reports Bun's virtual entry (src/index.js on 1.x, the
  // TUI worker on V2) as an argument. It is never a user argument.
  const bunVirtual = (value) => {
    const normalized = String(value).replaceAll("\\", "/");
    return normalized.includes("/$bunfs/") || normalized.includes("/~BUN/");
  };
  const filtered = raw.filter((value, index) => index === 0 || !bunVirtual(value));
  const first = path.basename(filtered[0] || "").toLowerCase();
  if (first.includes("opencode") || first.includes("open-code")) return filtered;
  const tail = filtered.slice(1);
  if (tail.length && /opencode|open-code/i.test(path.basename(tail[0]))) tail.shift();
  return [resolveExecutable("opencode"), ...tail];
}

function launchEnvironment(cwdValue, baseEnvironment = process.env) {
  const env = { ...baseEnvironment, CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC: "1" };
  delete env.AMP_API_KEY;
  // Any inherited capture describes a parent process: another agent, or an
  // OpenCode that started this one. Always describe this process's launch.
  delete env.CMUX_AGENT_LAUNCH_SUBROUTER_CLAUDE_RESUME_COMMAND;
  delete env.CMUX_AGENT_LAUNCH_SUBROUTER_CODEX_RESUME_COMMAND;
  delete env.CMUX_AGENT_LAUNCH_ROUTED_CLAUDE_ACCOUNT;
  const argv = launchArgv();
  env.CMUX_AGENT_LAUNCH_KIND = "opencode";
  env.CMUX_AGENT_LAUNCH_EXECUTABLE = argv[0] || resolveExecutable("opencode");
  env.CMUX_AGENT_LAUNCH_ARGV_B64 = Buffer.from(`${argv.join("\0")}\0`, "utf8").toString("base64");
  env.CMUX_AGENT_LAUNCH_CWD = cwdValue || process.cwd();
  return env;
}

/** Admit session restore without blocking the shared OpenCode service. */
export function dispatchSessionHook(eventName, payload, spawnImpl = spawn, baseEnvironment = process.env) {
  if (baseEnvironment.CMUX_OPENCODE_HOOKS_DISABLED === "1" || !baseEnvironment.CMUX_SURFACE_ID) return false;
  const cmux = baseEnvironment.CMUX_OPENCODE_CMUX_BIN || "cmux";
  try {
    const child = spawnImpl(cmux, ["hooks", "enqueue", "opencode", eventName], {
      env: launchEnvironment(payload.cwd, baseEnvironment),
      stdio: ["pipe", "ignore", "ignore"],
      detached: true,
    });
    child.stdin?.on?.("error", () => {});
    child.on?.("error", () => {});
    child.stdin?.end(JSON.stringify(payload));
    child.unref?.();
    return true;
  } catch (_) {
    return false;
  }
}

// OpenCode publishes these through session.error without ending the turn: a
// user interrupt (Esc) then goes idle, and a context overflow compacts and
// continues. The idle stop that follows is the turn's outcome.
const NON_TERMINAL_SESSION_ERRORS = new Set(["MessageAbortedError", "ContextOverflowError"]);

function sessionEventName(event) {
  const data = properties(event);
  if (event?.type === "session.created") return "session-start";
  if (event?.type === "session.deleted") return "session-end";
  if (event?.type === "session.updated") return data.info?.time?.archived ? "session-end" : null;
  // OpenCode keeps an execution interrupted by shutdown and resumes it.
  if (event?.type === "session.execution.interrupted" && data.reason === "shutdown") return null;
  if (["session.execution.succeeded", "session.execution.interrupted"].includes(event?.type)) return "stop";
  if (event?.type === "session.error" && NON_TERMINAL_SESSION_ERRORS.has(data.error?.name)) return null;
  if (["session.execution.failed", "session.next.step.failed", "session.error"].includes(event?.type)) return "stop-failure";
  if (event?.type === "session.idle") return "stop";
  if (event?.type === "session.status" && statusType(data.status) === "idle") return "stop";
  return null;
}

// True when the event shows the session running a turn. Message updates and
// queued prompts are not run signals: a queued prompt's message arrives while
// the previous turn is still running, and a repeated update after a stop must
// not reopen a finished turn.
function isTurnStart(event) {
  if (["session.created", "session.next.prompted", "session.execution.started"].includes(event?.type)) return true;
  return event?.type === "session.status" && statusType(properties(event).status) === "busy";
}

// A turn publishes exactly one terminal stop, and only a run signal opens the
// next one. The first terminal event settles the turn: a published stop cannot
// be reclassified, so a later idle or failure for the same turn is dropped.
function createTurnLedger() {
  const stopped = new Set();
  return {
    begin(id) { stopped.delete(id); },
    settle(id) {
      if (stopped.has(id)) return false;
      stopped.add(id);
      return true;
    },
    end(id) { stopped.delete(id); },
  };
}

function reportError(ctx, _error) {
  try {
    const toast = ctx?.ui?.toast?.show;
    if (typeof toast === "function") {
      toast.call(ctx.ui.toast, {
        message: "cmux could not process the OpenCode event. Try again.",
        variant: "error",
      });
    }
  } catch (_) {}
}

async function deliverEvent(ctx, feed, event, id, environment, turns) {
  const hook = sessionEventName(event);
  let admittedHook = hook;
  if (hook === "session-end") turns.end(id);
  if ((hook === "stop" || hook === "stop-failure") && !turns.settle(id)) admittedHook = null;
  if (admittedHook) {
    const payload = {
      session_id: id,
      cwd: cwd(ctx, event),
      event: event.type,
      hook_event_name: admittedHook === "stop-failure" ? "StopFailure" : admittedHook === "stop" ? "Stop" : event.type,
    };
    if (admittedHook === "stop-failure") {
      const error = failureMessage(event);
      if (error) payload.error = error;
    }
    dispatchSessionHook(admittedHook === "stop-failure" ? "stop" : admittedHook, payload, spawn, environment);
  }
  // The ownership check above is also the admission decision for the Feed
  // bridge. Avoid scanning the visible tab set a second time for this event.
  await feed.event({ event, ownedSessionId: id });
}

async function handleEvent(ctx, ownership, feed, details, environment, retrySessionStart, turns) {
  const event = details?.event || details;
  const id = sessionID(event);
  const hook = sessionEventName(event);
  if (!id) return;
  // Track turn boundaries even while the session is hidden, so a turn that
  // starts in a background tab still publishes its stop once visible again.
  if (isTurnStart(event)) turns?.begin(id);
  if (hook === "session-end") retrySessionStart?.cancel(id);
  if (!ownership.belongs(id)) {
    if (hook === "session-start") retrySessionStart?.enqueue(event, id);
    return;
  }
  if (hook === "session-start") retrySessionStart?.cancel(id);
  await deliverEvent(ctx, feed, event, id, environment, turns);
}

// The expiry bounds memory for sessions that never become visible. It only
// removes stale queue entries; route readiness is observed by Solid below.
const SESSION_START_QUEUE_TTL_MS = 30_000;

export async function createCMUXTUIBridge(ctx, options = {}) {
  const environment = { ...process.env, ...options.environment };
  let disposed = false;
  const turns = createTurnLedger();
  // Keep missed session-start events until the TUI reports a route/tab change.
  // The nested map lets session-end and delivery cancel one session in O(1).
  const pending = new Map();
  const cancelPending = (id) => {
    const queued = pending.get(id);
    if (!queued) return;
    clearTimeout(queued.expiry);
    pending.delete(id);
  };
  let feed;
  let ownership;
  const flushPending = () => {
    if (disposed || !feed || !ownership) return;
    for (const [id, queued] of pending) {
      if (!ownership.belongs(id)) continue;
      clearTimeout(queued.expiry);
      pending.delete(id);
      for (const event of queued.events.values()) {
        void handleEvent(ctx, ownership, feed, event, environment, {
          cancel: cancelPending,
          enqueue: enqueueSessionStart,
        }, turns).catch((error) => reportError(ctx, error));
      }
    }
  };
  ownership = createOwnership(ctx, flushPending);
  feed = await CMUXFeed(ctx, {
    tui: true,
    ownsSession: ownership.belongs,
    locationForSession: () => ctx?.location,
    environment,
  });
  function enqueueSessionStart(event, id) {
    if (disposed) return;
    let queued = pending.get(id);
    if (!queued) {
      queued = { events: new Map(), expiry: undefined };
      queued.expiry = setTimeout(() => {
        if (pending.get(id) === queued) pending.delete(id);
      }, SESSION_START_QUEUE_TTL_MS);
      pending.set(id, queued);
    }
    if (!queued.events.has(event.type)) queued.events.set(event.type, event);
  };
  const onEvent = ({ details, event }) => {
    const incoming = details || event;
    const incomingID = sessionID(incoming);
    if (sessionEventName(incoming) === "session-end") cancelPending(incomingID);
    // OpenCode v2 exposes route/tab state as reactive reads rather than a
    // stable callback. Re-check queued starts at every event boundary too, so
    // a restored route that commits between lifecycle events is admitted
    // without a wall-clock retry or a dropped final attempt.
    flushPending();
    void handleEvent(ctx, ownership, feed, incoming, environment, {
      cancel: cancelPending,
      enqueue: enqueueSessionStart,
    }, turns).catch((error) => reportError(ctx, error));
  };
  const stop = ctx.data.listen(onEvent);
  const disposeReactive = createRoot((dispose) => {
    createEffect(() => {
      // current() and list() are reactive reads in OpenCode v2. A route/tab
      // commit therefore flushes queued lifecycle events even when idle.
      ownership.refresh();
      flushPending();
    });
    return dispose;
  });
  flushPending();
  return () => {
    disposed = true;
    disposeReactive?.();
    for (const queued of pending.values()) clearTimeout(queued.expiry);
    pending.clear();
    stop?.();
    feed.dispose?.();
    ownership.dispose();
  };
}

export default {
  id: "cmux.tui",
  async tui(ctx) { return createCMUXTUIBridge(ctx); },
  // Compatibility alias for older V2 snapshots that called setup().
  async setup(ctx) { return createCMUXTUIBridge(ctx); },
};
