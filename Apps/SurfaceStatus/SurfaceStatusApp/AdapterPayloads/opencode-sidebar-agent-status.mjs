// cmux-surface-sidebar-opencode-status v2
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
    this.blockerIDs = new Set();
    this.anonymousBlockerCounts = new Map();
    this.hasWorked = false;
    this.terminalFailure = undefined;
    this.baseReport = { state: "idle" };
    this.lastReport = undefined;
  }

  observeSession(info, sessionID) {
    if (info?.id && info.parentID) {
      this.childParents.set(info.id, info.parentID);
    }
    // Metadata events can enumerate restored/background roots. Ownership is
    // claimed only by explicit chat/work/error/interaction events below.
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

  rootOf(sessionID) {
    if (!sessionID) return undefined;
    let current = sessionID;
    const visited = new Set();
    while (this.childParents.has(current) && !visited.has(current)) {
      visited.add(current);
      current = this.childParents.get(current);
    }
    return current;
  }

  isOwnedRoot(sessionID) {
    if (!sessionID) return !this.rootSessionID;
    if (!this.rootSessionID) {
      this.rootSessionID = this.rootOf(sessionID);
      return sessionID === this.rootSessionID;
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

  blocker(sessionID, kind, active, requestID) {
    if (!this.isOwnedInteraction(sessionID)) return;
    const baseKey = `${sessionID ?? "root"}:${kind}`;
    if (requestID) {
      const key = `${baseKey}:${requestID}`;
      if (active) this.blockerIDs.add(key);
      else this.blockerIDs.delete(key);
    } else {
      const current = this.anonymousBlockerCounts.get(baseKey) ?? 0;
      if (active) {
        this.anonymousBlockerCounts.set(baseKey, current + 1);
      } else if (current > 0) {
        const next = current - 1;
        if (next > 0) this.anonymousBlockerCounts.set(baseKey, next);
        else this.anonymousBlockerCounts.delete(baseKey);
      } else {
        // Some OpenCode versions omit request identity on replies. Remove one
        // matching identified blocker, never all of them at once.
        const prefix = `${baseKey}:`;
        const matching = this.blockerIDs.values().find((key) => key.startsWith(prefix));
        if (matching) this.blockerIDs.delete(matching);
      }
    }
    this.publishDesired();
  }

  release(sessionID) {
    if (sessionID && sessionID !== this.rootSessionID) return false;
    this.rootSessionID = undefined;
    this.childParents.clear();
    this.blockerIDs.clear();
    this.anonymousBlockerCounts.clear();
    this.hasWorked = false;
    this.terminalFailure = undefined;
    this.baseReport = { state: "idle" };
    this.lastReport = undefined;
    return true;
  }

  publishInitial() {
    this.publishDesired(true);
  }

  publishDesired(force = false) {
    const report = this.blockerIDs.size > 0 || this.anonymousBlockerCounts.size > 0
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
// Node records timeOrigin as Unix epoch milliseconds at process creation. The
// monitor compares this immutable process incarnation with proc_bsdinfo.
const processStartedAt = performance.timeOrigin / 1000;
const stateDirectory = path.join(os.homedir(), ".cmuxterm");
const statusFile = surfaceID
  ? path.join(stateDirectory, `${agentID}-${surfaceID}-sidebar-agent-status.json`)
  : undefined;
export function directStatusRecord({ state, reason }, context) {
  return {
    version: 3,
    agentID,
    surfaceID: context.surfaceID,
    workspaceID: context.workspaceID,
    state,
    reason,
    pid: context.pid,
    processStartedAt: context.processStartedAt,
    updatedAt: context.updatedAt,
  };
}
function report({ state, reason }) {
  if (!statusFile || !surfaceID) return;
  try {
    fs.mkdirSync(stateDirectory, { recursive: true, mode: 0o700 });
    const temporary = `${statusFile}.${process.pid}.tmp`;
    fs.writeFileSync(temporary, `${JSON.stringify(directStatusRecord(
      { state, reason },
      {
        surfaceID,
        workspaceID,
        pid: process.pid,
        processStartedAt,
        updatedAt: Date.now() / 1000,
      },
    ))}\n`, { mode: 0o600 });
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
      const requestID = properties.id ?? properties.requestID ?? properties.permissionID ?? properties.questionID;

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
          lifecycle.blocker(sessionID, "permission", true, requestID);
          break;
        case "question.asked":
          lifecycle.blocker(sessionID, "question", true, requestID);
          break;
        case "permission.replied":
          lifecycle.blocker(sessionID, "permission", false, requestID);
          lifecycle.working(sessionID);
          break;
        case "question.replied":
        case "question.rejected":
          lifecycle.blocker(sessionID, "question", false, requestID);
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
