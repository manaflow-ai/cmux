// cmux-opencode-tui-plugin-marker v2
// OpenCode V2 bridge loaded inside each TUI process.
// The server entry is inert; this module owns the TUI's cmux identity.

import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { CMUXFeed } from "./index.js";

const firstString = (...values) => values.find((value) => typeof value === "string" && value.trim())?.trim() || null;
const properties = (event) => event?.data || event?.properties || {};

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
    data.directory,
    data.cwd,
    ctx?.location?.directory,
    ctx?.directory,
    process.cwd(),
  );
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
    if (route?.type === "session" || route?.name === "session" || routeID) roots.add(rootFor(ctx, routeID));
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

function createOwnership(ctx) {
  let roots = new Set();
  const refresh = () => {
    roots = visibleRoots(ctx);
  };
  refresh();
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
    // Router and tab state are live, but the public TUI API does not expose a
    // stable change subscription on every supported OpenCode release. Resolve
    // ownership from the current state for each event so a closed starter
    // surface cannot retain a session after navigation changes.
    belongs: (id) => Boolean(id && sessionBelongsToTUI(ctx, id)),
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
  const worker = (value) => String(value).replaceAll("\\", "/").includes("/$bunfs/") && String(value).endsWith("/tui/worker.js");
  const filtered = raw.filter((value, index) => index === 0 || !worker(value));
  const first = path.basename(filtered[0] || "").toLowerCase();
  if (first.includes("opencode") || first.includes("open-code")) return filtered;
  const tail = filtered.slice(1);
  if (tail.length && /opencode|open-code/i.test(path.basename(tail[0]))) tail.shift();
  return [resolveExecutable("opencode"), ...tail];
}

function launchEnvironment(cwdValue, baseEnvironment = process.env) {
  const env = { ...baseEnvironment, CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC: "1" };
  delete env.AMP_API_KEY;
  if (!env.CMUX_AGENT_LAUNCH_ARGV_B64) {
    const argv = launchArgv();
    env.CMUX_AGENT_LAUNCH_KIND = "opencode";
    env.CMUX_AGENT_LAUNCH_EXECUTABLE = argv[0] || resolveExecutable("opencode");
    env.CMUX_AGENT_LAUNCH_ARGV_B64 = Buffer.from(`${argv.join("\0")}\0`, "utf8").toString("base64");
    env.CMUX_AGENT_LAUNCH_CWD = cwdValue || process.cwd();
  }
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

function sessionEventName(event) {
  const data = properties(event);
  if (event?.type === "session.created") return "session-start";
  if (event?.type === "session.deleted") return "session-end";
  if (event?.type === "session.updated") return data.info?.time?.archived ? "session-end" : "session-start";
  if (["session.execution.succeeded", "session.execution.failed", "session.execution.interrupted"].includes(event?.type)) return "stop";
  if (event?.type === "session.idle") return "stop";
  if (event?.type === "session.status" && (data.status?.type || data.status?.status || data.status) === "idle") return "stop";
  return null;
}

function reportError(ctx, error) {
  try {
    const report = ctx?.error || ctx?.ui?.error || ctx?.onError;
    if (typeof report === "function") report.call(ctx, error);
  } catch (_) {}
}

async function handleEvent(ctx, ownership, feed, details, environment) {
  const event = details?.event || details;
  const id = sessionID(event);
  if (!id || !ownership.belongs(id)) return;
  const hook = sessionEventName(event);
  if (hook) {
    dispatchSessionHook(hook, {
      session_id: id,
      cwd: cwd(ctx, event),
      event: event.type,
      hook_event_name: hook === "stop" ? "Stop" : event.type,
    }, spawn, environment);
  }
  await feed.event({ event });
}

export async function createCMUXTUIBridge(ctx, options = {}) {
  const environment = { ...process.env, ...options.environment };
  const ownership = createOwnership(ctx);
  const feed = await CMUXFeed(ctx, {
    tui: true,
    ownsSession: ownership.belongs,
    locationForSession: () => ctx?.location,
    environment,
  });
  const onEvent = ({ details, event }) => {
    void handleEvent(ctx, ownership, feed, details || event, environment).catch((error) => reportError(ctx, error));
  };
  const stop = ctx.data.listen(onEvent);
  return () => {
    stop?.();
    feed.dispose?.();
    ownership.dispose();
  };
}

export default {
  id: "cmux.tui",
  async setup(ctx) { return createCMUXTUIBridge(ctx); },
};
