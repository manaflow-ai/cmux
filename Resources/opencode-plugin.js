// cmux-feed-plugin-marker v1
// Bridges OpenCode's plugin event bus to the cmux socket's feed.* verbs.
// Installed by `cmux setup-hooks` or `cmux opencode install-hooks`.
// DO NOT EDIT MANUALLY — cmux upgrades this file in place.

const net = require("node:net");
const os = require("node:os");

const DEFAULT_SOCKET = `${os.homedir()}/.config/cmux/cmux.sock`;
const SOCKET_PATH = process.env.CMUX_SOCKET_PATH || DEFAULT_SOCKET;
const REPLY_TIMEOUT_MS = 120_000;

export const CMUXFeed = async (ctx) => {
  let client = null;
  let buffered = "";
  const pending = new Map();
  const messageRoles = new Map();
  const sessions = new Map();

  const normalizeText = (value, max = 1000) => {
    if (typeof value !== "string") return null;
    const normalized = value.replace(/\s+/g, " ").trim();
    if (!normalized) return null;
    return normalized.length > max ? `${normalized.slice(0, max - 1)}…` : normalized;
  };

  const sessionState = (sessionId) => {
    const key = sessionId || "unknown";
    if (!sessions.has(key)) {
      sessions.set(key, {
        lastUserMessage: null,
        assistantPreamble: null,
        cwd: null,
      });
    }
    return sessions.get(key);
  };

  const contextForSession = (sessionId) => {
    const state = sessionState(sessionId);
    const context = {};
    if (state.lastUserMessage) context.lastUserMessage = state.lastUserMessage;
    if (state.assistantPreamble) context.assistantPreamble = state.assistantPreamble;
    return Object.keys(context).length > 0 ? context : undefined;
  };

  const resolvePending = (requestId, value) => {
    if (!requestId || !pending.has(requestId)) return;
    const resolver = pending.get(requestId);
    pending.delete(requestId);
    resolver(value);
  };

  const failPending = () => {
    for (const requestId of pending.keys()) {
      resolvePending(requestId, { status: "timed_out" });
    }
    buffered = "";
  };

  const connect = () => {
    try {
      const conn = net.createConnection(SOCKET_PATH);
      conn.setEncoding("utf8");
      conn.on("data", (chunk) => {
        buffered += chunk;
        let idx;
        while ((idx = buffered.indexOf("\n")) >= 0) {
          const line = buffered.slice(0, idx);
          buffered = buffered.slice(idx + 1);
          if (!line) continue;
          try {
            const msg = JSON.parse(line);
            // The socket sends either V2 responses (id/ok/result/error)
            // or push frames keyed by request_id. We only care about
            // results whose result.decision matches a waiter.
            const responseId =
              typeof msg?.id === "string" && msg.id.startsWith("opencode-")
                ? msg.id.slice("opencode-".length)
                : null;
            const requestId = msg?.result?.request_id || msg?.request_id || responseId;
            resolvePending(requestId, msg.result || msg);
          } catch (e) {
            // swallow — malformed line, keep the connection alive.
          }
        }
      });
      conn.on("close", () => {
        client = null;
        failPending();
      });
      conn.on("error", () => {
        client = null;
        failPending();
      });
      return conn;
    } catch (e) {
      failPending();
      return null;
    }
  };

  const write = (frame) => {
    if (!client) client = connect();
    if (!client) return false;
    try {
      client.write(JSON.stringify(frame) + "\n");
      return true;
    } catch (e) {
      failPending();
      return false;
    }
  };

  const base = (sessionId, extra) => {
    const state = sessionState(sessionId);
    const context = extra?.context || contextForSession(sessionId);
    const event = {
      session_id: `opencode-${sessionId}`,
      _source: "opencode",
      _ppid: process.pid,
      cwd: extra?.cwd || state.cwd || ctx?.directory,
      ...extra,
    };
    if (context) event.context = context;
    return event;
  };

  const trackMessage = (event) => {
    const props = event.properties || {};
    if (event.type === "message.updated") {
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
      return null;
    }

    if (event.type !== "message.part.updated") return null;
    const part = props.part || {};
    if (part.type !== "text" || !part.messageID) return null;
    const meta = messageRoles.get(part.messageID);
    if (!meta) return null;
    const text = normalizeText(part.text || part.textDelta || part.content);
    if (!text) return null;
    const state = sessionState(meta.sessionId);
    if (meta.role === "user") {
      state.lastUserMessage = text;
      return base(meta.sessionId, {
        hook_event_name: "UserPromptSubmit",
        tool_input: { prompt: text },
        context: { lastUserMessage: text },
      });
    }
    if (meta.role === "assistant") {
      state.assistantPreamble = text;
    }
    return null;
  };

  const pushBlocking = (event, requestId) => {
    const reply = new Promise((resolve) => {
      pending.set(requestId, resolve);
      setTimeout(() => {
        if (pending.has(requestId)) {
          pending.delete(requestId);
          resolve({ status: "timed_out" });
        }
      }, REPLY_TIMEOUT_MS);
    });
    const wrote = write({
      id: `opencode-${requestId}`,
      method: "feed.push",
      params: { event, wait_timeout_seconds: REPLY_TIMEOUT_MS / 1000 },
    });
    if (!wrote) {
      resolvePending(requestId, { status: "timed_out" });
    }
    return reply;
  };

  const pushTelemetry = (event) => {
    write({
      id: `opencode-telemetry-${Date.now()}`,
      method: "feed.push",
      params: { event, wait_timeout_seconds: 0 },
    });
  };

  return {
    event: async ({ event }) => {
      const tracked = trackMessage(event);
      if (tracked) {
        pushTelemetry(tracked);
        return;
      }
      switch (event.type) {
        case "session.created": {
          const info = event.properties?.info || {};
          const state = sessionState(info.id || "unknown");
          state.cwd = info.directory || ctx?.directory || state.cwd;
          pushTelemetry(base(info.id || "unknown", {
            hook_event_name: "SessionStart",
            cwd: state.cwd,
          }));
          break;
        }
        case "session.idle": {
          const sid = event.properties?.sessionID;
          if (!sid) break;
          pushTelemetry(base(sid, {
            hook_event_name: "Stop",
          }));
          break;
        }
        case "session.deleted": {
          const sid = event.properties?.info?.id;
          if (!sid) break;
          sessions.delete(sid);
          pushTelemetry(base(sid, {
            hook_event_name: "SessionEnd",
          }));
          break;
        }
        case "todo.updated": {
          const sid = event.properties?.sessionID;
          if (!sid) break;
          pushTelemetry(base(sid, {
            hook_event_name: "TodoWrite",
            tool_input: event.properties?.todos || [],
          }));
          break;
        }
        case "permission.asked": {
          const props = event.properties || {};
          const requestId = props.id;
          if (!requestId) break;
          const sid = props.sessionID || "unknown";
          const frame = base(sid, {
            hook_event_name: "PermissionRequest",
            _opencode_request_id: requestId,
            tool_name: props.tool,
            tool_input: props.input,
          });
          const result = await pushBlocking(frame, requestId);
          if (result?.status === "resolved" && result.decision?.kind === "permission") {
            const mode = result.decision.mode;
            const response = mode === "deny" ? "deny" : "approve";
            const remember = (mode === "always" || mode === "all" || mode === "bypass");
            try {
              await ctx.client.session.permissions({
                path: { id: sid, permissionID: requestId },
                body: { response, remember },
              });
            } catch (e) { /* ignore — opencode already moved on */ }
          }
          break;
        }
        case "question.asked": {
          const props = event.properties || {};
          const requestId = props.id;
          const sid = props.sessionID || "unknown";
          if (!requestId) break;
          const questions = (props.questions || []).map((q, idx) => ({
            id: q.id || `q${idx}`,
            header: q.header || q.title,
            question: q.question || q.prompt || "",
            multiSelect: q.multiSelect || q.multiple || false,
            options: (q.options || []).map((o, optionIdx) => ({
              id: o.id || `opt${optionIdx}`,
              label: o.label || o.title || String(o),
              description: o.description || o.detail,
            })),
          }));
          const frame = base(sid, {
            hook_event_name: "AskUserQuestion",
            _opencode_request_id: requestId,
            tool_name: "AskUserQuestion",
            tool_input: { questions },
          });
          await pushBlocking(frame, requestId);
          break;
        }
        default:
          // Non-Feed-worthy events pass silently to keep the plugin cheap.
          break;
      }
    },
  };
};
