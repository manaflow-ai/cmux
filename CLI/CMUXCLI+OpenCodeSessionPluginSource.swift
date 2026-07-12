import Foundation

extension CMUXCLI {
    static let openCodeSessionPluginMarker = "cmux-opencode-session-plugin-marker"
    static let openCodeSessionPluginFilename = "cmux-session.js"
    static let openCodeSessionPluginSource = #"""
// cmux-opencode-session-plugin-marker v1
// Bridges OpenCode session lifecycle events into cmux's restorable session store.
// Installed by `cmux hooks opencode install` or `cmux hooks setup`.
// DO NOT EDIT MANUALLY. cmux upgrades this file in place.

import { spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";

const CMUX_PLUGIN_INSTALLED_KEY = Symbol.for("cmux.session.restore.plugin.installed");
const MAX_TRACKED_SESSIONS = 100;
const messageRoles = new Map();
const sessions = new Map();

function firstString(...values) {
  for (const value of values) {
    if (typeof value === "string" && value.trim().length > 0) return value.trim();
  }
  return null;
}

function eventProperties(event) {
  return (event && typeof event === "object" && event.properties) || {};
}

function normalizeText(value, max = 1000) {
  if (typeof value !== "string") return null;
  const normalized = value.replace(/\s+/g, " ").trim();
  if (!normalized) return null;
  return normalized.length > max ? `${normalized.slice(0, max - 3)}...` : normalized;
}

function sessionState(sessionId) {
  const key = sessionId || "unknown";
  if (!sessions.has(key)) {
    sessions.set(key, {
      lastUserMessage: null,
      assistantPreamble: null,
      cwd: null,
      started: false,
      activeTurn: false,
      retrying: false,
      updatedAt: Date.now(),
    });
  }
  const state = sessions.get(key);
  state.updatedAt = Date.now();
  pruneSessions();
  return state;
}

function pruneSessions() {
  while (sessions.size > MAX_TRACKED_SESSIONS) {
    let oldestKey = null;
    let oldestUpdatedAt = Infinity;
    for (const [key, state] of sessions.entries()) {
      const updatedAt = Number(state && state.updatedAt) || 0;
      if (updatedAt < oldestUpdatedAt) {
        oldestUpdatedAt = updatedAt;
        oldestKey = key;
      }
    }
    if (!oldestKey) break;
    dropSession(oldestKey);
  }
}

function dropSession(sessionId) {
  const key = sessionId || "unknown";
  sessions.delete(key);
  for (const [messageId, meta] of messageRoles.entries()) {
    if (meta && meta.sessionId === key) {
      messageRoles.delete(messageId);
    }
  }
}

function contextForSession(sessionId) {
  const state = sessionState(sessionId);
  const context = {};
  if (state.lastUserMessage) context.lastUserMessage = state.lastUserMessage;
  if (state.assistantPreamble) context.assistantPreamble = state.assistantPreamble;
  return Object.keys(context).length > 0 ? context : undefined;
}

function sessionIdFor(event) {
  const props = eventProperties(event);
  return firstString(
    props.info && props.info.id,
    props.sessionID,
    props.sessionId,
    props.session_id,
    props.session && props.session.id,
    event && event.sessionID,
    event && event.sessionId
  );
}

function cwdFor(ctx, event) {
  const props = eventProperties(event);
  return firstString(
    props.info && props.info.directory,
    props.cwd,
    props.directory,
    ctx && ctx.directory,
    process.cwd()
  );
}

function openCodeStatusType(event) {
  const props = eventProperties(event);
  const status = props.status || (props.info && props.info.status) || (event && event.status);
  return firstString(
    status && status.type,
    status && status.status,
    status && status.state,
    props.status,
    props.type,
    props.state
  );
}

function isRetryingStatus(value) {
  return String(value || "").toLowerCase().includes("retry");
}

function isIdleStatus(value) {
  const normalized = String(value || "").toLowerCase();
  return normalized === "idle" || normalized === "done" || normalized === "stopped";
}

function isRunningStatus(value) {
  const normalized = String(value || "").toLowerCase();
  return [
    "active",
    "busy",
    "running",
    "streaming",
    "thinking",
    "working",
  ].includes(normalized);
}

function openCodeEventMessage(event) {
  const props = eventProperties(event);
  const candidates = [
    props.message,
    props.body,
    props.text,
    props.error && props.error.message,
    props.error,
    props.question && props.question.question,
    props.question && props.question.prompt,
    props.permission && props.permission.message,
    props.permission && props.permission.description,
    props.title,
  ];
  return firstString(...candidates);
}

function resolveExecutable(name) {
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

function looksLikeOpenCodeScript(value) {
  if (!value) return false;
  const lower = String(value).toLowerCase();
  return lower.includes("opencode") || lower.includes("open-code");
}

function isOpenCodeInternalWorkerArg(value) {
  if (!value) return false;
  const normalized = String(value).replaceAll("\\", "/");
  return normalized.includes("/$bunfs/") && normalized.endsWith("/tui/worker.js");
}

function withoutOpenCodeInternalWorkerArgs(argv) {
  const result = [];
  for (let i = 0; i < argv.length; i += 1) {
    const value = argv[i];
    if (i > 0 && isOpenCodeInternalWorkerArg(value)) continue;
    result.push(value);
  }
  return result.length > 0 ? result : [resolveExecutable("opencode")];
}

function normalizedLaunchArgv() {
  const raw = Array.isArray(process.argv) ? process.argv.map((value) => String(value)) : [];
  if (raw.length === 0) return [resolveExecutable("opencode")];

  const firstBase = path.basename(raw[0]).toLowerCase();
  if (looksLikeOpenCodeScript(firstBase)) return withoutOpenCodeInternalWorkerArgs(raw);

  let tail = raw.slice(1);
  if (tail.length > 0 && looksLikeOpenCodeScript(tail[0])) {
    tail = tail.slice(1);
  }
  return withoutOpenCodeInternalWorkerArgs([resolveExecutable("opencode"), ...tail]);
}

function base64NulSeparated(values) {
  const bytes = [];
  for (const value of values) {
    bytes.push(Buffer.from(String(value), "utf8"));
    bytes.push(Buffer.from([0]));
  }
  return Buffer.concat(bytes).toString("base64");
}

function hookEnvironment(cwd) {
  const env = { ...process.env };
  delete env.AMP_API_KEY;
  if (!env.CMUX_AGENT_LAUNCH_ARGV_B64) {
    const argv = normalizedLaunchArgv();
    env.CMUX_AGENT_LAUNCH_KIND = "opencode";
    env.CMUX_AGENT_LAUNCH_EXECUTABLE = argv[0] || resolveExecutable("opencode");
    env.CMUX_AGENT_LAUNCH_ARGV_B64 = base64NulSeparated(argv);
    env.CMUX_AGENT_LAUNCH_CWD = cwd || process.cwd();
  }
  return env;
}

function sendHook(subcommand, ctx, event, extra = {}) {
  if (process.env.CMUX_OPENCODE_HOOKS_DISABLED === "1") return false;
  if (!process.env.CMUX_SURFACE_ID) return false;

  const sessionId = sessionIdFor(event);
  if (!sessionId) return false;

  const cwd = cwdFor(ctx, event);
  const state = sessionState(sessionId);
  state.cwd = cwd || state.cwd;
  const payload = {
    session_id: sessionId,
    cwd,
    event: event && event.type,
    hook_event_name: event && event.type,
    ...extra,
  };
  const context = extra.context || contextForSession(sessionId);
  if (context) payload.context = context;
  const cmux = process.env.CMUX_OPENCODE_CMUX_BIN || "cmux";
  try {
    const result = spawnSync(cmux, ["hooks", "opencode", subcommand], {
      input: JSON.stringify(payload),
      encoding: "utf8",
      env: hookEnvironment(cwd),
      stdio: ["pipe", "ignore", "ignore"],
      timeout: 5000,
    });
    return !result.error && result.status === 0 && !result.signal;
  } catch (_) {}
  return false;
}

function sendStartOnce(ctx, event) {
  const sessionId = sessionIdFor(event);
  if (!sessionId) return;
  const state = sessionState(sessionId);
  if (state.started) return;
  if (sendHook("session-start", ctx, event)) {
    state.started = true;
  }
}

function sendPromptSubmitOnce(ctx, event) {
  const sessionId = sessionIdFor(event);
  if (!sessionId) return;
  const state = sessionState(sessionId);
  if (state.activeTurn) return;
  if (sendHook("prompt-submit", ctx, event)) {
    state.activeTurn = true;
    state.retrying = false;
  }
}

function sendStopIfActive(ctx, event) {
  const sessionId = sessionIdFor(event);
  if (!sessionId) return;
  const state = sessionState(sessionId);
  if (!state.activeTurn && !state.retrying) return;
  if (sendHook("stop", ctx, event)) {
    state.activeTurn = false;
    state.retrying = false;
  }
}

function trackMessage(event) {
  const props = eventProperties(event);
  if (event && event.type === "message.updated") {
    const info = props.info || props.message || {};
    const messageId = info.id || props.messageID;
    const sessionId = info.sessionID || props.sessionID;
    const role = info.role || props.role;
    if (messageId && sessionId && role) {
      messageRoles.set(messageId, { sessionId, role });
      if (messageRoles.size > 300) {
        messageRoles.delete(messageRoles.keys().next().value);
      }
    }
    return;
  }

  if (!event || event.type !== "message.part.updated") return;
  const part = props.part || {};
  if (part.type !== "text" || !part.messageID) return;
  const meta = messageRoles.get(part.messageID);
  if (!meta) return;
  const text = normalizeText(part.text || part.textDelta || part.content);
  if (!text) return;
  const state = sessionState(meta.sessionId);
  if (meta.role === "user") {
    state.lastUserMessage = text;
  } else if (meta.role === "assistant") {
    state.assistantPreamble = text;
  }
}

const CMUXSessionRestore = async (ctx) => {
  if (globalThis[CMUX_PLUGIN_INSTALLED_KEY]) return {};
  globalThis[CMUX_PLUGIN_INSTALLED_KEY] = true;
  return {
    event: async ({ event }) => {
      trackMessage(event);
      const props = eventProperties(event);
      switch (event && event.type) {
        case "session.created":
          sendStartOnce(ctx, event);
          break;
        case "session.updated":
          if (props.info && props.info.time && props.info.time.archived) {
            sendStopIfActive(ctx, event);
            sendHook("session-end", ctx, event);
            dropSession(sessionIdFor(event));
          } else {
            sendStartOnce(ctx, event);
          }
          break;
        case "session.status":
          if (isIdleStatus(openCodeStatusType(event))) {
            sendStopIfActive(ctx, event);
          } else if (isRetryingStatus(openCodeStatusType(event))) {
            const sessionId = sessionIdFor(event);
            if (sessionId) sessionState(sessionId).retrying = true;
            sendHook("notification", ctx, event, {
              cmux_status: "retrying",
              reason: "retrying",
            });
          } else if (isRunningStatus(openCodeStatusType(event))) {
            sendPromptSubmitOnce(ctx, event);
          }
          break;
        case "session.idle":
          sendStopIfActive(ctx, event);
          break;
        case "permission.asked":
          sendHook("notification", ctx, event, {
            message: openCodeEventMessage(event),
            reason: "permission_prompt",
          });
          break;
        case "question.asked":
          sendHook("notification", ctx, event, {
            message: openCodeEventMessage(event),
            reason: "question answer",
          });
          break;
        case "session.error":
          sendHook("notification", ctx, event, {
            message: "Agent reported an error",
            reason: "error",
          });
          sendStopIfActive(ctx, event);
          break;
        case "session.deleted":
          sendStopIfActive(ctx, event);
          sendHook("session-end", ctx, event);
          dropSession(sessionIdFor(event));
          break;
        default:
          break;
      }
    },
  };
};

export { CMUXSessionRestore };
export default CMUXSessionRestore;
"""#

}
