// cmux-feed-plugin-marker v1
// Bridges OpenCode's plugin event bus to the cmux socket's feed.* verbs.
// Installed by `cmux hooks setup` or `cmux hooks opencode install`.
// DO NOT EDIT MANUALLY - cmux upgrades this file in place.

import net from "node:net";
import os from "node:os";
import fs from "node:fs";
import path from "node:path";

const DEFAULT_SOCKET = `${os.homedir()}/.config/cmux/cmux.sock`;
const REPLY_TIMEOUT_MS = 120_000;
const MAX_PLAN_BYTES = 128 * 1024;

const createCMUXFeed = async (ctx, options = {}) => {
  const environment = { ...process.env, ...options.environment };
  const socketPath = environment.CMUX_SOCKET_PATH || DEFAULT_SOCKET;
  const ownsSession = options.ownsSession || (() => true);
  const locationForSession = options.locationForSession || (() => ctx?.location);
  let disposed = false;
  let client = null;
  let buffered = "";
  let telemetrySequence = 0;
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

  const eventProperties = (event) => {
    if (!event || typeof event !== "object") return {};
    // V1 delivered payloads under `properties`; V2 uses `data`.
    return event.properties || event.data || {};
  };

  // OpenCode has emitted both session.idle and session.status events over
  // time, and the session identifier moved between top-level and nested
  // properties. Keep the feed bridge tolerant of those wire-shape changes so
  // completion notifications do not depend on one particular OpenCode build.
  const sessionIdFromProperties = (props = {}) => firstString(
    props.info && props.info.sessionID,
    props.info && props.info.id,
    props.sessionID,
    props.sessionId,
    props.session_id,
    props.session && props.session.id
  );

  const sessionIdFromEvent = (event) => {
    const props = eventProperties(event);
    const info = props.info || props.message || {};
    const part = props.part || {};
    const permission = props.permission || {};
    const sessionEventID = event?.type?.startsWith("session.") ? info.id : null;
    return firstString(
      props.sessionID,
      props.sessionId,
      props.session_id,
      props.form && props.form.sessionID,
      props.form && props.form.sessionId,
      props.form && props.form.session_id,
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
  };

  const sessionStatusIsIdle = (status) => {
    if (typeof status === "string") return status.toLowerCase() === "idle";
    if (!isObject(status)) return false;
    return firstString(status.type, status.status, status.state)?.toLowerCase() === "idle";
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

  const ownsSessionForEvent = async (sessionId, ownerSessionId = null) => {
    if (ownerSessionId && sessionId === ownerSessionId) return true;
    return await ownsSession(sessionId);
  };

  const replyPermission = async ({ sessionId, requestId, reply, message, ownerSessionId = null }) => {
    if (disposed || !(await ownsSessionForEvent(sessionId, ownerSessionId))) return;
    if (options.tui) {
      await ctx.client.permission.reply({
        sessionID: sessionId,
        requestID: requestId,
        decision: reply,
        ...(message ? { message } : {}),
      });
      return;
    }
    // OpenCode v2 exposes permission operations on the plugin context and
    // scopes the request by session. Keep the HTTP fallback for SDK builds
    // that do not expose the domain helper yet.
    try {
      if (await callClientMethod(ctx?.permission, "reply", {
        sessionID: sessionId,
        requestID: requestId,
        reply,
      })) return;
    } catch (_) {}
    if (
      await tryRawClientRequest("post", {
        url: "/api/session/{sessionID}/permission/{requestID}/reply",
        path: { sessionID: sessionId, requestID: requestId },
        body: message ? { decision: reply, message } : { decision: reply },
      })
    ) return;
    // OpenCode v1 compatibility.
    if (
      await tryRawClientRequest("post", {
        url: "/permission/{requestID}/reply",
        path: { requestID: requestId },
        body: message ? { reply, message } : { reply },
      })
    ) return;
    try {
      if (await callClientMethod(ctx?.client?.permission, "reply", { requestID: requestId, reply, message })) return;
    } catch (_) {}
    if (sessionId) {
      await callClientMethod(ctx?.client, "postSessionIdPermissionsPermissionId", {
        path: { id: sessionId, permissionID: requestId },
        body: legacyPermissionBody(reply),
      });
    }
  };

  const replyForm = async (sessionId, formId, answer, legacyAnswers = null, ownerSessionId = null) => {
    if (disposed || !(await ownsSessionForEvent(sessionId, ownerSessionId))) return;
    if (options.tui) {
      if (legacyAnswers) {
        if (
          await tryRawClientRequest("post", {
            url: "/question/{requestID}/reply",
            path: { requestID: formId },
            body: { answers: legacyAnswers },
          })
        ) return;
        const reply = ctx?.client?.question?.reply;
        if (typeof reply === "function") {
          await reply.call(ctx.client.question, { requestID: formId, answers: legacyAnswers });
          return;
        }
      }
      await ctx.data.session.form.reply({
        sessionID: sessionId,
        formID: formId,
        answer,
      }, locationForSession(sessionId));
      return;
    }
    try {
      if (await callClientMethod(ctx?.form, "reply", { sessionID: sessionId, formID: formId, answer })) return;
    } catch (_) {}
    if (
      await tryRawClientRequest("post", {
        url: "/api/session/{sessionID}/form/{formID}/reply",
        path: { sessionID: sessionId, formID: formId },
        body: { answer },
      })
    ) return;
    // OpenCode v1 compatibility for question.asked.
    const answers = legacyAnswers || Object.values(answer).map((value) => Array.isArray(value) ? value.map(String) : [String(value)]);
    if (
      await tryRawClientRequest("post", {
        url: "/question/{requestID}/reply",
        path: { requestID: formId },
        body: { answers },
      })
    ) return;
    await callClientMethod(ctx?.client?.question, "reply", { requestID: formId, answers });
  };

  const rejectQuestion = async (requestId) => {
    if (
      await tryRawClientRequest("post", {
        url: "/question/{requestID}/reject",
        path: { requestID: requestId },
        body: {},
      })
    ) return;
    await callClientMethod(ctx?.client?.question, "reject", { requestID: requestId });
  };

  const updateSessionPermission = async (sessionId, permission, ownerSessionId = null) => {
    if (disposed || !(await ownsSessionForEvent(sessionId, ownerSessionId))) return false;
    if (!sessionId || !permission.length) return true;
    const permissions = permission.map((rule) => ({
      action: rule.permission,
      resource: rule.pattern,
      effect: rule.action === "allow" ? "allow" : rule.action === "deny" ? "deny" : "ask",
    }));
    if (options.tui) {
      try {
        await ctx.client.session.update({ sessionID: sessionId, permissions });
        return true;
      } catch (_) {
        return false;
      }
    }
    try {
      if (await callClientMethod(ctx?.permission, "rules", { sessionID: sessionId, permissions })) return true;
    } catch (_) {}
    if (
      await tryRawClientRequest("patch", {
        url: "/api/session/{sessionID}",
        path: { sessionID: sessionId },
        body: { permissions },
      })
    ) return true;
    // OpenCode v1 compatibility.
    if (
      await tryRawClientRequest("patch", {
        url: "/session/{sessionID}",
        path: { sessionID: sessionId },
        body: { permission },
      })
    ) return true;
    return await callClientMethod(ctx?.client?.session, "update", { path: { id: sessionId }, body: { permission } });
  };

  const sendPlanFeedback = async (sessionId, text, ownerSessionId = null) => {
    const message = normalizeText(text, 2000);
    if (!sessionId || !message || disposed || !(await ownsSessionForEvent(sessionId, ownerSessionId))) return;
    if (options.tui) {
      try {
        await ctx.client.session.prompt({ sessionID: sessionId, text: message, resume: false });
        return;
      } catch (_) {}
      await ctx.client.session.synthetic({ sessionID: sessionId, text: message, resume: false });
      return;
    }
    try {
      if (await callClientMethod(ctx?.session, "prompt", { sessionID: sessionId, text: message })) return;
    } catch (_) {}
    if (
      await tryRawClientRequest("post", {
        url: "/api/session/{sessionID}/prompt",
        path: { sessionID: sessionId },
        body: { text: message },
      })
    ) return;
    // OpenCode 2.0.11 exposes synthetic input as the stable plugin-domain
    // operation when the prompt helper has a stricter PromptInput shape.
    try {
      if (await callClientMethod(ctx?.session, "synthetic", {
        sessionID: sessionId,
        text: message,
        resume: false,
      })) return;
    } catch (_) {}
    // OpenCode v1 compatibility.
    const body = { agent: "plan", parts: [{ type: "text", text: message }] };
    if (
      await tryRawClientRequest("post", {
        url: "/session/{sessionID}/prompt_async",
        path: { sessionID: sessionId },
        body,
      })
    ) return;
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

  const formInfoFromEvent = (event) => {
    const props = eventProperties(event);
    const form = props.form || props.info || props;
    const formId = firstString(form.id, form.formID, form.formId, props.formID, props.formId);
    const sessionId = firstString(form.sessionID, form.sessionId, props.sessionID, props.sessionId, props.session_id);
    const fields = Array.isArray(form.fields) ? form.fields : Array.isArray(props.fields) ? props.fields : [];
    if (!formId || !sessionId || fields.length === 0) return null;
    return { formId, sessionId, title: firstString(form.title, form.name, form.description), fields };
  };

  const questionsForForm = (form) => form.fields.map((field, index) => {
    const options = Array.isArray(field.options) ? field.options.map((option, optionIndex) => ({
      id: option.id || option.value || `opt${optionIndex}`,
      label: option.label || option.title || option.name || String(option.value ?? option),
      description: option.description || option.detail,
    })) : [];
    return {
      id: field.key || field.id || field.name || `field${index}`,
      header: field.header || field.title || form.title,
      question: field.label || field.title || field.description || field.name || "",
      multiSelect: field.multiple === true || field.multiSelect === true || field.type === "array" || field.type === "multiselect",
      options,
    };
  });

  const answerForForm = (form, selections) => {
    const optionValue = (field, value) => {
      const selected = String(value ?? "");
      const option = (Array.isArray(field.options) ? field.options : []).find((candidate) => (
        String(candidate.value ?? "") === selected ||
        String(candidate.id ?? "") === selected ||
        String(candidate.label ?? candidate.title ?? candidate.name ?? "") === selected
      ));
      return option?.value ?? option?.id ?? option?.label ?? option?.title ?? option?.name ?? selected;
    };
    const answer = {};
    const values = Array.isArray(selections) ? selections : [];
    form.fields.forEach((field, index) => {
      const key = field.key || field.id || field.name || `field${index}`;
      const multiSelect = field.multiple === true || field.multiSelect === true || field.type === "array" || field.type === "multiselect";
      const fieldValue = multiSelect && form.fields.length === 1 ? values : (values[index] ?? values[0]);
      if (multiSelect) {
        const rawValues = Array.isArray(fieldValue)
          ? fieldValue
          : fieldValue == null || fieldValue === ""
            ? []
            : String(fieldValue).split(/,\s*/);
        answer[key] = rawValues.map((value) => optionValue(field, value));
      } else if (field.type === "number" || field.type === "integer") {
        answer[key] = fieldValue == null || fieldValue === "" ? 0 : Number(fieldValue);
      } else if (field.type === "boolean") {
        answer[key] = fieldValue === true || fieldValue === "true" || fieldValue === "Yes";
      } else {
        answer[key] = fieldValue == null ? "" : optionValue(field, fieldValue);
      }
    });
    return answer;
  };

  const replyInteractive = async (sid, requestId, answer, legacyAnswers, ownerSessionId = null) => {
    await replyForm(sid, requestId, answer, legacyAnswers, ownerSessionId);
  };

  const handleExitPlanDecision = async (sid, requestId, decision, form = null, ownerSessionId = null) => {
    const mode = decision?.mode || "manual";
    const planDecisionAnswer = (value) => form ? answerForForm(form, [value]) : { answer: value };
    const replyPlanAnswer = async (value) => {
      if (form) {
        await replyInteractive(sid, requestId, planDecisionAnswer(value), null, ownerSessionId);
      } else {
        await replyInteractive(sid, requestId, planDecisionAnswer(value), [[value]], ownerSessionId);
      }
    };
    const feedback = normalizeText(decision?.feedback, 1800);

    if (feedback) {
      await replyPlanAnswer("No");
      await sendPlanFeedback(
        sid,
        `User rejected the plan via cmux Feed and wants this change: ${feedback}\n\nUpdate the plan file, then call plan_exit again.`,
        ownerSessionId
      );
      return;
    }

    if (mode === "deny") {
      await replyPlanAnswer("No");
      return;
    }

    if (mode === "ultraplan") {
      await replyPlanAnswer("No");
      await sendPlanFeedback(
        sid,
        "User chose Ultraplan via cmux Feed. Refine the plan more deeply, update the plan file, then call plan_exit again.",
        ownerSessionId
      );
      return;
    }

    const rules = permissionRulesForExitPlanMode(mode);
    let permissionsApplied = true;
    try {
      permissionsApplied = await updateSessionPermission(sid, rules, ownerSessionId);
    } catch (_) {
      permissionsApplied = false;
    }
    if (!permissionsApplied) {
      await replyPlanAnswer("No");
      await sendPlanFeedback(
        sid,
        "cmux could not apply the selected permission mode. Ask the user to approve the plan again before switching to build mode.",
        ownerSessionId
      );
      return;
    }
    await replyPlanAnswer("Yes");
  };

  const resolvePending = (requestId, value) => {
    if (!requestId || !pending.has(requestId)) return;
    const resolver = pending.get(requestId);
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
      const conn = net.createConnection(socketPath);
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
      typeof environment.CMUX_WORKSPACE_ID === "string" && environment.CMUX_WORKSPACE_ID.trim()
        ? environment.CMUX_WORKSPACE_ID.trim()
        : null;
    const surfaceId =
      typeof environment.CMUX_SURFACE_ID === "string" && environment.CMUX_SURFACE_ID.trim()
        ? environment.CMUX_SURFACE_ID.trim()
        : null;
    const event = {
      session_id: `opencode-${sessionId}`,
      _source: "opencode",
      _ppid: process.pid,
      cwd: extra?.cwd || state.cwd || ctx?.directory,
      ...extra,
    };
    if (workspaceId) event.workspace_id = workspaceId;
    if (surfaceId) event.surface_id = surfaceId;
    if (context) event.context = context;
    return event;
  };

  const trackMessage = (event) => {
    const props = eventProperties(event);
    if (event.type === "session.inbox.enqueued") {
      const sid = firstString(props.sessionID);
      const item = props.item || {};
      const text = normalizeText(item.type === "user" ? item.payload?.text : null);
      if (!sid || !text) return null;
      const state = sessionState(sid);
      state.lastUserMessage = text;
      return base(sid, {
        hook_event_name: "UserPromptSubmit",
        tool_input: { prompt: text },
        context: { lastUserMessage: text },
      });
    }
    if (event.type === "session.text.ended") {
      const sid = firstString(props.sessionID);
      const text = normalizeText(props.text);
      if (sid && text) sessionState(sid).assistantPreamble = text;
      return null;
    }
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
      let timeout;
      const finish = (value) => {
        if (!pending.has(requestId)) return;
        pending.delete(requestId);
        if (timeout) clearTimeout(timeout);
        resolve(value);
      };
      pending.set(requestId, finish);
      timeout = setTimeout(() => {
        if (pending.has(requestId)) {
          pending.delete(requestId);
          resolve({ status: "timed_out" });
        }
      }, REPLY_TIMEOUT_MS);
      timeout.unref?.();
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
    telemetrySequence += 1;
    write({
      // Date.now() alone collides when OpenCode publishes a burst of events
      // in one event-loop turn. The monotonic suffix keeps socket request IDs
      // unique without relying on randomness or a second clock.
      id: `opencode-telemetry-${Date.now()}-${telemetrySequence}`,
      method: "feed.push",
      params: { event, wait_timeout_seconds: 0 },
    });
  };

  const handleEvent = async (event, ownedSessionId = null) => {
      if (options.tui) {
        const sid = sessionIdFromEvent(event);
        if (!sid || (sid !== ownedSessionId && !(await ownsSession(sid)))) return;
      }
      const tracked = trackMessage(event);
      if (tracked) {
        pushTelemetry(tracked);
        return;
      }
      switch (event.type) {
        case "session.created": {
          const props = eventProperties(event);
          const info = props.info || {};
          const sid = sessionIdFromProperties(props) || "unknown";
          const state = sessionState(sid);
          state.cwd = info.directory || props.location?.directory || event.location?.directory || ctx?.location?.directory || ctx?.directory || state.cwd;
          pushTelemetry(base(sid, {
            hook_event_name: "SessionStart",
            cwd: state.cwd,
          }));
          break;
        }
        case "session.status": {
          const props = eventProperties(event);
          if (!sessionStatusIsIdle(props.status)) break;
          const sid = sessionIdFromProperties(props);
          if (!sid) break;
          pushTelemetry(base(sid, {
            hook_event_name: "Stop",
          }));
          break;
        }
        case "session.execution.succeeded":
        case "session.execution.failed":
        case "session.execution.interrupted": {
          const sid = sessionIdFromEvent(event);
          if (sid) pushTelemetry(base(sid, { hook_event_name: "Stop" }));
          break;
        }
        case "session.updated": {
          const sid = sessionIdFromEvent(event);
          if (!sid) break;
          if (eventProperties(event).info?.time?.archived) {
            pushTelemetry(base(sid, { hook_event_name: "SessionEnd" }));
            sessions.delete(sid);
          } else {
            pushTelemetry(base(sid, { hook_event_name: "SessionStart" }));
          }
          break;
        }
        case "session.idle": {
          const sid = sessionIdFromProperties(eventProperties(event));
          if (!sid) break;
          pushTelemetry(base(sid, {
            hook_event_name: "Stop",
          }));
          break;
        }
        case "session.deleted": {
          const sid = sessionIdFromProperties(eventProperties(event));
          if (!sid) break;
          sessions.delete(sid);
          pushTelemetry(base(sid, {
            hook_event_name: "SessionEnd",
          }));
          break;
        }
        case "todo.updated": {
          const sid = eventProperties(event).sessionID;
          if (!sid) break;
          pushTelemetry(base(sid, {
            hook_event_name: "TodoWrite",
            tool_input: eventProperties(event).todos || [],
          }));
          break;
        }
        case "permission.asked": {
          const props = eventProperties(event);
          const nestedPermission = isObject(props.permission) ? props.permission : {};
          const request = props;
          const requestId = firstString(request.id, request.requestID, request.requestId, nestedPermission.id, nestedPermission.requestID);
          if (!requestId) break;
          const sid = firstString(request.sessionID, request.sessionId, nestedPermission.sessionID, nestedPermission.sessionId) || "unknown";
          const permission = firstString(request.action, request.permission, nestedPermission.action, nestedPermission.permission, request.tool?.name, nestedPermission.tool?.name) || "permission";
          const resources = Array.isArray(request.resources)
            ? request.resources
            : (Array.isArray(nestedPermission.resources) ? nestedPermission.resources : []);
          const metadata = isObject(request.metadata) ? request.metadata : {};
          const frame = base(sid, {
            hook_event_name: "PermissionRequest",
            _opencode_request_id: requestId,
            tool_name: permission,
            tool_input: {
              action: request.action,
              resources,
              permission,
              patterns: resources.length > 0 ? resources : (Array.isArray(request.patterns) ? request.patterns : []),
              always: Array.isArray(request.always) ? request.always : [],
              save: request.save,
              source: request.source,
              message: request.message,
              metadata,
              tool: request.tool,
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
              await updateSessionPermission(sid, permissionSessionRulesForMode(permission, mode), ownedSessionId);
            } catch (_) {}
            try {
              await replyPermission({
                sessionId: sid,
                requestId,
                reply: permissionReplyForMode(mode),
                message: mode === "deny" ? "User denied permission via cmux Feed." : undefined,
                ownerSessionId: ownedSessionId,
              });
            } catch (e) { /* ignore - opencode already moved on */ }
          }
          break;
        }
        case "form.created":
        case "form.updated":
        case "form.asked":
        case "session.form": {
          const form = formInfoFromEvent(event);
          if (!form) break;
          const requestId = form.formId;
          const questions = questionsForForm(form);
          const planExit = planExitInfo(form.sessionId, questions);
          const hookEventName = planExit ? "ExitPlanMode" : "AskUserQuestion";
          const frame = base(form.sessionId, {
            hook_event_name: hookEventName,
            _opencode_request_id: requestId,
            tool_name: planExit ? "plan_exit" : "form",
            tool_input: planExit ? {
              plan: planExit.plan,
              planFilePath: planExit.planFilePath,
              question: planExit.question,
            } : { questions },
            context: {
              ...(contextForSession(form.sessionId) || {}),
              permissionMode: planExit ? "plan" : "opencode",
            },
          });
          const result = await pushBlocking(frame, requestId);
          if (result?.status !== "resolved") break;
          try {
            if (planExit && result.decision?.kind === "exit_plan") {
              await handleExitPlanDecision(form.sessionId, requestId, result.decision, form, ownedSessionId);
            } else if (!planExit && result.decision?.kind === "question") {
              await replyForm(form.sessionId, requestId, answerForForm(form, result.decision.selections), null, ownedSessionId);
            }
          } catch (_) {}
          break;
        }
        case "question.asked": {
          const props = eventProperties(event);
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
                await handleExitPlanDecision(sid, requestId, result.decision, null, ownedSessionId);
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
              await replyForm(sid, requestId, {}, questionAnswers(result.decision.selections), ownedSessionId);
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
  };

  return {
    event: async ({ event, ownedSessionId }) => {
      if (!disposed) await handleEvent(event?.event || event, ownedSessionId || null);
    },
    dispose() {
      disposed = true;
      client?.destroy();
      client = null;
      for (const requestId of pending.keys()) resolvePending(requestId, { status: "timed_out" });
      messageRoles.clear();
      sessions.clear();
    },
  };
};

export const CMUXFeed = createCMUXFeed;

export default {
  id: "cmux.server",
  // V2 uses the package's ./tui export; never subscribe in the shared service.
  setup() { return () => {}; },
};
