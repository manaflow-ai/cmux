// cmux-feed-plugin-marker v1
// Bridges OpenCode's plugin event bus to the cmux socket's feed.* verbs.
// Installed by `cmux hooks setup` or `cmux hooks opencode install`.
// DO NOT EDIT MANUALLY - cmux upgrades this file in place.

const net = require("node:net");
const os = require("node:os");
const fs = require("node:fs");
const path = require("node:path");

const DEFAULT_SOCKET = `${os.homedir()}/.config/cmux/cmux.sock`;
const SOCKET_PATH = process.env.CMUX_SOCKET_PATH || DEFAULT_SOCKET;
const REPLY_TIMEOUT_MS = 120_000;
const MAX_PLAN_BYTES = 128 * 1024;

export const CMUXFeed = async (ctx) => {
  let client = null;
  let buffered = "";
  const pending = new Map();
  const messageRoles = new Map();
  const sessions = new Map();

  const isObject = (value) => value && typeof value === "object" && !Array.isArray(value);

  const firstString = (...values) => {
    for (const value of values) {
      if (typeof value === "string" && value.trim().length > 0) return value.trim();
    }
    return null;
  };

  const normalizeText = (value, max = 1000) => {
    if (typeof value !== "string") return null;
    const normalized = value.replace(/\s+/g, " ").trim();
    if (!normalized) return null;
    return normalized.length > max ? `${normalized.slice(0, max - 3)}...` : normalized;
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

  const clientMethod = (root, name) => {
    const fn = root?.[name];
    return typeof fn === "function" ? fn.bind(root) : null;
  };

  const rawClientRequest = async (method, options) => {
    const raw = ctx?.client?._client || ctx?.client?.client;
    const fn = raw && typeof raw[method] === "function" ? raw[method].bind(raw) : null;
    if (!fn) throw new Error(`OpenCode SDK raw ${method} unavailable`);
    return await fn({
      ...options,
      throwOnError: true,
      headers: { "Content-Type": "application/json", ...(options.headers || {}) },
    });
  };

  const tryRawClientRequest = async (method, options) => {
    try {
      await rawClientRequest(method, options);
      return true;
    } catch (_) {
      return false;
    }
  };

  const callClientMethod = async (root, name, args) => {
    const fn = clientMethod(root, name);
    if (!fn) return false;
    await fn(args);
    return true;
  };

  const legacyPermissionBody = (reply) => ({
    response: reply === "reject" ? "deny" : "approve",
    remember: reply === "always",
  });

  const replyPermission = async ({ sessionId, requestId, reply, message }) => {
    if (
      await tryRawClientRequest("post", {
        url: "/permission/{requestID}/reply",
        path: { requestID: requestId },
        body: message ? { reply, message } : { reply },
      })
    ) {
      return;
    }

    if (await callClientMethod(ctx?.client?.permission, "reply", { requestID: requestId, reply, message })) {
      return;
    }

    if (sessionId) {
      await callClientMethod(ctx?.client, "postSessionIdPermissionsPermissionId", {
        path: { id: sessionId, permissionID: requestId },
        body: legacyPermissionBody(reply),
      });
    }
  };

  const replyQuestion = async (requestId, answers) => {
    if (
      await tryRawClientRequest("post", {
        url: "/question/{requestID}/reply",
        path: { requestID: requestId },
        body: { answers },
      })
    ) {
      return;
    }

    await callClientMethod(ctx?.client?.question, "reply", { requestID: requestId, answers });
  };

  const rejectQuestion = async (requestId) => {
    if (
      await tryRawClientRequest("post", {
        url: "/question/{requestID}/reject",
        path: { requestID: requestId },
        body: {},
      })
    ) {
      return;
    }

    await callClientMethod(ctx?.client?.question, "reject", { requestID: requestId });
  };

  const updateSessionPermission = async (sessionId, permission) => {
    if (!sessionId || !permission.length) return true;
    if (
      await tryRawClientRequest("patch", {
        url: "/session/{sessionID}",
        path: { sessionID: sessionId },
        body: { permission },
      })
    ) {
      return true;
    }

    return await callClientMethod(ctx?.client?.session, "update", { path: { id: sessionId }, body: { permission } });
  };

  const sendPlanFeedback = async (sessionId, text) => {
    const message = normalizeText(text, 2000);
    if (!sessionId || !message) return;
    const body = {
      agent: "plan",
      parts: [{ type: "text", text: message }],
    };
    if (
      await tryRawClientRequest("post", {
        url: "/session/{sessionID}/prompt_async",
        path: { sessionID: sessionId },
        body,
      })
    ) {
      return;
    }

    await callClientMethod(ctx?.client?.session, "promptAsync", { path: { id: sessionId }, body });
  };

  const permissionRulesForExitPlanMode = (mode) => {
    switch (mode) {
      case "manual":
        return [
          { permission: "edit", pattern: "*", action: "ask" },
          { permission: "bash", pattern: "*", action: "ask" },
          { permission: "external_directory", pattern: "*", action: "ask" },
        ];
      case "autoAccept":
      case "bypassPermissions":
        return [
          { permission: "edit", pattern: "*", action: "allow" },
          { permission: "bash", pattern: "*", action: "allow" },
          { permission: "external_directory", pattern: "*", action: "allow" },
        ];
      default:
        return [];
    }
  };

  const permissionReplyForMode = (mode) => {
    switch (mode) {
      case "deny":
        return "reject";
      case "always":
      case "all":
      case "bypass":
        return "always";
      default:
        return "once";
    }
  };

  const permissionSessionRulesForMode = (permission, mode) => {
    if (!permission) return [];
    switch (mode) {
      case "all":
      case "bypass":
        return [{ permission: "*", pattern: "*", action: "allow" }];
      default:
        return [];
    }
  };

  const questionAnswers = (selections) => {
    if (!Array.isArray(selections) || selections.length === 0) return [[]];
    return selections.map((selection) => [String(selection)]);
  };

  const resolveSessionPlanPath = (sid, rawPlanPath) => {
    if (!rawPlanPath) return null;
    const root = path.resolve(sessionState(sid).cwd || ctx?.worktree || ctx?.directory || process.cwd());
    const raw = String(rawPlanPath);
    const relativeInput = path.isAbsolute(raw)
      ? path.relative(root, path.resolve(raw))
      : raw;
    const candidate = path.resolve(root, relativeInput);
    const relative = path.relative(root, candidate);
    if (!relative || relative.startsWith("..") || path.isAbsolute(relative)) return null;
    return candidate;
  };

  const readPlanFile = (planFilePath) => {
    const stat = fs.statSync(planFilePath);
    if (!stat.isFile()) return null;
    const fd = fs.openSync(planFilePath, "r");
    try {
      const length = Math.min(stat.size, MAX_PLAN_BYTES);
      const buffer = Buffer.alloc(length);
      const bytes = fs.readSync(fd, buffer, 0, length, 0);
      const text = buffer.subarray(0, bytes).toString("utf8");
      if (stat.size <= bytes) return text;
      return `${text}\n\n[cmux truncated plan file at ${bytes} bytes.]`;
    } finally {
      fs.closeSync(fd);
    }
  };

  const planExitInfo = (sid, questions) => {
    const first = Array.isArray(questions) ? questions[0] : null;
    if (!first) return null;
    const prompt = firstString(first.question, first.prompt) || "";
    const header = firstString(first.header, first.title) || "";
    const labels = Array.isArray(first.options)
      ? first.options.map((option) => firstString(option?.label, option?.title, option)).filter(Boolean)
      : [];
    const looksLikePlanExit =
      header === "Build Agent" ||
      /Plan at .+ is complete\./.test(prompt) ||
      (labels.includes("Yes") && labels.includes("No") && /switch to the build agent/i.test(prompt));
    if (!looksLikePlanExit) return null;

    const match = prompt.match(/Plan at (.+?) is complete\./);
    const rawPlanPath = match?.[1]?.trim();
    const planFilePath = resolveSessionPlanPath(sid, rawPlanPath);
    let plan = null;
    if (planFilePath) {
      try {
        plan = readPlanFile(planFilePath);
      } catch (_) {}
    }
    return {
      sid,
      question: prompt,
      plan: plan || prompt || "OpenCode plan is ready for review.",
      planFilePath,
    };
  };

  const handleExitPlanDecision = async (sid, requestId, decision) => {
    const mode = decision?.mode || "manual";
    const feedback = normalizeText(decision?.feedback, 1800);

    if (feedback) {
      await replyQuestion(requestId, [["No"]]);
      await sendPlanFeedback(
        sid,
        `User rejected the plan via cmux Feed and wants this change: ${feedback}\n\nUpdate the plan file, then call plan_exit again.`
      );
      return;
    }

    if (mode === "deny") {
      await replyQuestion(requestId, [["No"]]);
      return;
    }

    if (mode === "ultraplan") {
      await replyQuestion(requestId, [["No"]]);
      await sendPlanFeedback(
        sid,
        "User chose Ultraplan via cmux Feed. Refine the plan more deeply, update the plan file, then call plan_exit again."
      );
      return;
    }

    const rules = permissionRulesForExitPlanMode(mode);
    let permissionsApplied = true;
    try {
      permissionsApplied = await updateSessionPermission(sid, rules);
    } catch (_) {
      permissionsApplied = false;
    }
    if (!permissionsApplied) {
      await replyQuestion(requestId, [["No"]]);
      await sendPlanFeedback(
        sid,
        "cmux could not apply the selected permission mode. Ask the user to approve the plan again before switching to build mode."
      );
      return;
    }
    await replyQuestion(requestId, [["Yes"]]);
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
            // swallow - malformed line, keep the connection alive.
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
    const workspaceId =
      typeof process.env.CMUX_WORKSPACE_ID === "string" && process.env.CMUX_WORKSPACE_ID.trim()
        ? process.env.CMUX_WORKSPACE_ID.trim()
        : null;
    const event = {
      session_id: `opencode-${sessionId}`,
      _source: "opencode",
      _ppid: process.pid,
      cwd: extra?.cwd || state.cwd || ctx?.directory,
      ...extra,
    };
    if (workspaceId) event.workspace_id = workspaceId;
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
          const permission = firstString(props.permission, props.tool?.name) || "permission";
          const metadata = isObject(props.metadata) ? props.metadata : {};
          const frame = base(sid, {
            hook_event_name: "PermissionRequest",
            _opencode_request_id: requestId,
            tool_name: permission,
            tool_input: {
              permission,
              patterns: Array.isArray(props.patterns) ? props.patterns : [],
              always: Array.isArray(props.always) ? props.always : [],
              metadata,
              tool: props.tool,
            },
            context: {
              ...(contextForSession(sid) || {}),
              permissionMode: "opencode",
            },
          });
          const result = await pushBlocking(frame, requestId);
          if (result?.status === "resolved" && result.decision?.kind === "permission") {
            const mode = result.decision.mode;
            try {
              await updateSessionPermission(sid, permissionSessionRulesForMode(permission, mode));
            } catch (_) {}
            try {
              await replyPermission({
                sessionId: sid,
                requestId,
                reply: permissionReplyForMode(mode),
                message: mode === "deny" ? "User denied permission via cmux Feed." : undefined,
              });
            } catch (e) { /* ignore - opencode already moved on */ }
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
            multiSelect: q.multiSelect === true || q.multiple === true,
            options: (q.options || []).map((o, optionIdx) => ({
              id: o.id || `opt${optionIdx}`,
              label: o.label || o.title || String(o),
              description: o.description || o.detail,
            })),
          }));
          const planExit = planExitInfo(sid, questions);
          if (planExit) {
            const frame = base(sid, {
              hook_event_name: "ExitPlanMode",
              _opencode_request_id: requestId,
              tool_name: "plan_exit",
              tool_input: {
                plan: planExit.plan,
                planFilePath: planExit.planFilePath,
                question: planExit.question,
              },
              context: {
                ...(contextForSession(sid) || {}),
                permissionMode: "plan",
              },
            });
            const result = await pushBlocking(frame, requestId);
            if (result?.status === "resolved" && result.decision?.kind === "exit_plan") {
              try {
                await handleExitPlanDecision(sid, requestId, result.decision);
              } catch (_) {}
            }
            break;
          }

          const frame = base(sid, {
            hook_event_name: "AskUserQuestion",
            _opencode_request_id: requestId,
            tool_name: "question",
            tool_input: { questions },
          });
          const result = await pushBlocking(frame, requestId);
          if (result?.status === "resolved" && result.decision?.kind === "question") {
            try {
              await replyQuestion(requestId, questionAnswers(result.decision.selections));
            } catch (_) {
              try { await rejectQuestion(requestId); } catch (_) {}
            }
          }
          break;
        }
        default:
          // Non-Feed-worthy events pass silently to keep the plugin cheap.
          break;
      }
    },
  };
};
