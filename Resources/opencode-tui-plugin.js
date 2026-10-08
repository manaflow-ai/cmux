// cmux-opencode-tui-plugin-marker v1
// OpenCode V2 CLI/TUI bridge. This module is loaded in each TUI process.
// It deliberately has no server event subscription.

import net from "node:net";
import { spawn } from "node:child_process";
import os from "node:os";

const DEFAULT_SOCKET = `${os.homedir()}/.config/cmux/cmux.sock`;
const SOCKET_PATH = process.env.CMUX_SOCKET_PATH || DEFAULT_SOCKET;
const MAX_EVENT_TEXT = 1000;

const firstString = (...values) => values.find((value) => typeof value === "string" && value.trim())?.trim() || null;
const properties = (event) => event?.data || event?.properties || {};
const sessionID = (event) => {
  const data = properties(event);
  return firstString(data.sessionID, data.sessionId, data.session_id, data.info?.id, data.info?.sessionID, data.permission?.sessionID, data.permission?.sessionId, event?.sessionID);
};
const cwd = (ctx, event) => firstString(properties(event).info?.directory, properties(event).directory, ctx?.location?.directory, ctx?.directory, process.cwd());
const compact = (value) => typeof value === "string" ? value.replace(/\s+/g, " ").trim().slice(0, MAX_EVENT_TEXT) : null;

function visibleSessionIDs(ctx) {
  const ids = [];
  const current = ctx?.ui?.router?.current?.();
  if (current?.type === "session") ids.push(current.sessionID || current.sessionId || current.id);
  if (ctx?.ui?.tabs?.enabled?.() !== false) {
    for (const tab of ctx?.ui?.tabs?.list?.() || []) {
      ids.push(typeof tab === "string" ? tab : tab?.sessionID || tab?.sessionId || tab?.id);
    }
  }
  return ids.filter(Boolean);
}

/** Return true when a session is shown by this TUI's route or tabs. */
export async function sessionBelongsToTUI(ctx, id) {
  if (!id) return false;
  const visible = visibleSessionIDs(ctx);
  if (visible.length === 0) return false;
  const root = (candidate) => {
    try { return ctx?.data?.session?.root?.(candidate) || candidate; } catch (_) { return candidate; }
  };
  const targetRoot = root(id);
  return visible.some((candidate) => root(candidate) === targetRoot);
}

function launchEnvironment(cwdValue) {
  const env = { ...process.env, CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC: "1" };
  if (cwdValue) env.CMUX_AGENT_LAUNCH_CWD = cwdValue;
  return env;
}

/** Dispatch session restore asynchronously so one TUI cannot block the shared service. */
export function dispatchSessionHook(eventName, payload, spawnImpl = spawn) {
  if (process.env.CMUX_OPENCODE_HOOKS_DISABLED === "1" || !process.env.CMUX_SURFACE_ID) return false;
  const cmux = process.env.CMUX_OPENCODE_CMUX_BIN || "cmux";
  const child = spawnImpl(cmux, ["hooks", "enqueue", "opencode", eventName], {
    env: launchEnvironment(payload.cwd),
    stdio: ["pipe", "ignore", "ignore"],
  });
  child.stdin?.end(JSON.stringify(payload));
  child.stdin?.on?.("error", () => {});
  child.on?.("error", () => {});
  child.unref?.();
  return true;
}

function feedPush(event) {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (value) => { if (!settled) { settled = true; resolve(value); } };
    const socket = net.createConnection(SOCKET_PATH);
    let buffered = "";
    socket.setEncoding("utf8");
    socket.on("data", (chunk) => {
      buffered += chunk;
      let index;
      while ((index = buffered.indexOf("\n")) >= 0) {
        const line = buffered.slice(0, index); buffered = buffered.slice(index + 1);
        try {
          const message = JSON.parse(line);
          if (message?.result?.request_id || message?.request_id || message?.id) finish(message.result || message);
        } catch (_) {}
      }
    });
    socket.once("error", () => finish(null));
    socket.once("close", () => finish(null));
    socket.setTimeout?.(120000, () => { socket.destroy(); finish(null); });
    socket.write(JSON.stringify({
      id: `opencode-${Date.now()}-${Math.random().toString(16).slice(2)}`,
      method: "feed.push",
      params: { event, wait_timeout_seconds: 120 },
    }) + "\n");
  });
}

function permissionFrame(id, request) {
  const data = properties(request);
  const permission = data.permission || data;
  return {
    session_id: `opencode-${id}`,
    _source: "opencode",
    _ppid: process.pid,
    surface_id: process.env.CMUX_SURFACE_ID,
    workspace_id: process.env.CMUX_WORKSPACE_ID,
    cwd: firstString(permission.directory, data.directory),
    hook_event_name: "PermissionRequest",
    _opencode_request_id: firstString(permission.id, permission.requestID, data.id),
    tool_name: firstString(permission.action, permission.permission, permission.tool?.name) || "permission",
    tool_input: permission,
  };
}

async function handleEvent(ctx, details) {
  const id = sessionID(details);
  if (!id || !(await sessionBelongsToTUI(ctx, id))) return;
  const type = details?.type;
  const data = properties(details);
  if (["session.created", "session.updated", "session.deleted"].includes(type)) {
    dispatchSessionHook(type === "session.deleted" ? "session-end" : "session-start", {
      session_id: id, cwd: cwd(ctx, details), event: type, hook_event_name: type,
    });
    return;
  }
  if (type === "session.idle" || (type === "session.status" && (data.status?.type || data.status) === "idle")) {
    dispatchSessionHook("stop", { session_id: id, cwd: cwd(ctx, details), event: type, hook_event_name: "Stop" });
    return;
  }
  if (type === "permission.asked") {
    const frame = permissionFrame(id, details);
    const result = await feedPush(frame);
    if (result?.status !== "resolved" || !result.decision || !ctx.client?.permission?.reply) return;
    const decision = result.decision.mode === "deny" ? "reject" : result.decision.mode === "always" ? "always" : "once";
    await ctx.client.permission.reply({ sessionID: id, requestID: frame._opencode_request_id, decision });
    return;
  }
  if (["form.created", "form.updated", "form.asked", "session.form"].includes(type)) {
    const form = data.form || data;
    const formID = firstString(form.id, form.formID, form.formId, data.formID, data.formId);
    if (!formID || !ctx.data?.session?.form?.reply) return;
    const result = await feedPush({
      session_id: `opencode-${id}`, _source: "opencode", surface_id: process.env.CMUX_SURFACE_ID,
      workspace_id: process.env.CMUX_WORKSPACE_ID, hook_event_name: "AskUserQuestion",
      _opencode_request_id: formID, tool_name: "form", tool_input: form,
    });
    if (result?.status === "resolved" && result.decision?.kind === "question") {
      await ctx.data.session.form.reply({ sessionID: id, formID, answer: result.decision.selections || {} }, ctx.location);
    }
  }
}

export function createCMUXTUIBridge(ctx) {
  const stop = ctx.data.listen(({ details }) => { void handleEvent(ctx, details); });
  return () => stop?.();
}

export default {
  id: "cmux.tui",
  setup(ctx) { return createCMUXTUIBridge(ctx); },
};
