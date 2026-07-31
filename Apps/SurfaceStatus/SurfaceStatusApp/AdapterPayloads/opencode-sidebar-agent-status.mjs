// cmux-surface-sidebar-opencode-status v1
// Reports OpenCode lifecycle states using cmux's own sidebar status contract.
// Installed by the CMUX Surface Status companion app.

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

const rateLimitPattern = /rate.?limit|quota exceeded|too many requests|429/i;

function sessionIDFromProperties(properties) {
  if (typeof properties?.sessionID === "string" && properties.sessionID) return properties.sessionID;
  if (typeof properties?.info?.id === "string" && properties.info.id) return properties.info.id;
  return undefined;
}

function safeErrorMessage(properties) {
  const candidates = [
    properties?.error?.message,
    properties?.error?.data?.message,
    properties?.status?.message,
    properties?.message,
  ];
  const message = candidates.find((value) => typeof value === "string" && value.trim());
  return typeof message === "string" ? message.trim().slice(0, 1000) : undefined;
}

export function classifyOpenCodeError(properties) {
  const errorMessage = safeErrorMessage(properties);
  if (errorMessage && rateLimitPattern.test(errorMessage)) {
    return { state: "rateLimited", reason: "rateLimit" };
  }
  return { state: "needsInput", reason: "error" };
}

export class OpenCodeSidebarLifecycle {
  constructor(publish) {
    this.publish = publish;
    this.rootSessionID = undefined;
    this.childParents = new Map();
    this.blockers = new Set();
    this.hasWorked = false;
    this.terminalFailure = undefined;
    this.baseReport = { state: "idle" };
    this.lastReport = undefined;
  }

  observeSession(info, sessionID) {
    if (info?.id && info.parentID) {
      this.childParents.set(info.id, info.parentID);
      return false;
    }
    // Claim the first root only. Background/restored roots observed by the same
    // plugin process must never steal the visible surface's ownership.
    if (!this.rootSessionID && sessionID) {
      this.rootSessionID = sessionID;
      return true;
    }
    return false;
  }

  descendsFromOwnedRoot(sessionID) {
    if (!sessionID || !this.rootSessionID) return false;
    let current = sessionID;
    const visited = new Set();
    while (this.childParents.has(current) && !visited.has(current)) {
      visited.add(current);
      current = this.childParents.get(current);
      if (current === this.rootSessionID) return true;
    }
    return false;
  }

  isOwnedRoot(sessionID) {
    if (!sessionID) return !this.rootSessionID;
    if (!this.rootSessionID) {
      this.rootSessionID = sessionID;
      return true;
    }
    return sessionID === this.rootSessionID;
  }

  isOwnedInteraction(sessionID) {
    return this.isOwnedRoot(sessionID) || this.descendsFromOwnedRoot(sessionID);
  }

  working(sessionID) {
    if (!this.isOwnedRoot(sessionID)) return;
    this.hasWorked = true;
    this.terminalFailure = undefined;
    this.baseReport = { state: "running" };
    this.publishDesired();
  }

  idle(sessionID) {
    if (!this.isOwnedRoot(sessionID)) return;
    if (this.terminalFailure) return;
    this.baseReport = { state: this.hasWorked ? "done" : "idle" };
    this.publishDesired();
  }

  error(sessionID, properties) {
    if (!this.isOwnedRoot(sessionID)) return;
    this.hasWorked = true;
    this.terminalFailure = classifyOpenCodeError(properties);
    this.baseReport = this.terminalFailure;
    this.publishDesired();
  }

  blocker(sessionID, kind, active) {
    if (!this.isOwnedInteraction(sessionID)) return;
    const key = `${sessionID ?? "root"}:${kind}`;
    if (active) this.blockers.add(key);
    else this.blockers.delete(key);
    this.publishDesired();
  }

  release(sessionID) {
    if (sessionID && sessionID !== this.rootSessionID) return false;
    this.rootSessionID = undefined;
    this.childParents.clear();
    this.blockers.clear();
    return true;
  }

  publishInitial() {
    this.publishDesired(true);
  }

  publishDesired(force = false) {
    const report = this.blockers.size > 0
      ? { state: "needsInput", reason: "interaction" }
      : this.baseReport;
    if (!force && JSON.stringify(report) === JSON.stringify(this.lastReport)) return;
    this.lastReport = report;
    this.publish(report);
  }
}

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const rawSurfaceID = process.env.CMUX_SURFACE_ID;
const surfaceID = rawSurfaceID && uuidPattern.test(rawSurfaceID) ? rawSurfaceID : undefined;
const rawWorkspaceID = process.env.CMUX_WORKSPACE_ID;
const workspaceID = rawWorkspaceID && uuidPattern.test(rawWorkspaceID) ? rawWorkspaceID : undefined;
const agentID = "opencode";
const stateDirectory = path.join(os.homedir(), ".cmuxterm");
const statusFile = surfaceID
  ? path.join(stateDirectory, `${agentID}-${surfaceID}-sidebar-agent-status.json`)
  : undefined;
function report({ state, reason }) {
  if (!statusFile || !surfaceID) return;
  try {
    fs.mkdirSync(stateDirectory, { recursive: true, mode: 0o700 });
    const temporary = `${statusFile}.${process.pid}.tmp`;
    fs.writeFileSync(temporary, `${JSON.stringify({
      version: 2,
      agentID,
      surfaceID,
      workspaceID,
      state,
      reason,
      pid: process.pid,
      updatedAt: Date.now() / 1000,
    })}\n`, { mode: 0o600 });
    fs.renameSync(temporary, statusFile);
  } catch {
    // Sidebar telemetry must never interfere with OpenCode.
  }
}

function removeOwnedStatus() {
  if (!statusFile) return;
  try {
    const current = JSON.parse(fs.readFileSync(statusFile, "utf8"));
    if (current?.pid === process.pid) fs.unlinkSync(statusFile);
  } catch {
    // A missing, replaced, or malformed status file is harmless.
  }
}

export const CmuxSidebarAgentStatusPlugin = async () => {
  if (!surfaceID) return {};

  const lifecycle = new OpenCodeSidebarLifecycle(report);
  lifecycle.publishInitial();
  process.once("exit", removeOwnedStatus);

  return {
    dispose: async () => removeOwnedStatus(),
    "chat.message": async ({ sessionID }) => lifecycle.working(sessionID),
    event: async ({ event }) => {
      const type = event?.type;
      const properties = event?.properties ?? {};
      const sessionID = sessionIDFromProperties(properties);
      lifecycle.observeSession(properties.info, sessionID);

      switch (type) {
        case "session.created":
        case "session.updated":
          break;
        case "session.status": {
          const status = typeof properties.status === "string"
            ? properties.status
            : properties.status?.type;
          switch (String(status ?? "").toLowerCase()) {
            case "idle": lifecycle.idle(sessionID); break;
            case "active":
            case "busy":
            case "pending":
            case "running":
            case "streaming":
            case "working":
            case "retry": lifecycle.working(sessionID); break;
            default: break;
          }
          break;
        }
        case "tool.execute.before":
        case "tool.execute.after":
        case "session.compacted":
          lifecycle.working(sessionID);
          break;
        case "permission.asked":
          lifecycle.blocker(sessionID, "permission", true);
          break;
        case "question.asked":
          lifecycle.blocker(sessionID, "question", true);
          break;
        case "permission.replied":
          lifecycle.blocker(sessionID, "permission", false);
          lifecycle.working(sessionID);
          break;
        case "question.replied":
        case "question.rejected":
          lifecycle.blocker(sessionID, "question", false);
          lifecycle.working(sessionID);
          break;
        case "session.error":
          lifecycle.error(sessionID, properties);
          break;
        case "session.idle":
          lifecycle.idle(sessionID);
          break;
        case "session.deleted":
          if (lifecycle.release(sessionID)) removeOwnedStatus();
          break;
        default:
          break;
      }
    },
  };
};
