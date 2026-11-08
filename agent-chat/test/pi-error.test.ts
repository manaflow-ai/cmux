import { piHandleLineForTest, piNextSendTypeForTest } from "../adapters/pi";
import type { AgentEvent, SessionCtx, SessionStatus } from "../types";

const events: AgentEvent[] = [];
const sess: SessionCtx = {
  id: "pi-test",
  provider: "pi",
  cwd: "/tmp",
  title: "pi test",
  autoApprove: true,
  startOptions: {},
  status: "running",
  events,
  internal: {
    pi: {
      nextId: 1,
      pending: new Map(),
      model: "",
      modelChoices: [],
      thinking: "minimal",
      thinkingNormalized: true,
      commands: [],
      initialApplied: true,
      activeTurn: true,
    },
  },
  emit(evt) {
    events.push(evt);
  },
  setStatus(status: SessionStatus) {
    this.status = status;
  },
};

piHandleLineForTest(sess, JSON.stringify({ type: "error", message: "provider exploded" }));
if (sess.status !== "idle") throw new Error(`pi error should set session idle, got ${sess.status}`);
if (piNextSendTypeForTest(sess) !== "prompt") throw new Error("next pi send after error should start a new prompt, not steer");
if (!events.some((evt) => evt.kind === "error" && /provider exploded/.test(evt.message))) {
  throw new Error(`pi error event missing: ${JSON.stringify(events)}`);
}
if (events.filter((evt) => evt.kind === "done").length !== 1) {
  throw new Error(`pi error should emit exactly one done footer, got ${JSON.stringify(events)}`);
}

piHandleLineForTest(sess, JSON.stringify({ type: "agent_end" }));
if (events.filter((evt) => evt.kind === "done").length !== 1) {
  throw new Error(`late agent_end should not duplicate done footer, got ${JSON.stringify(events)}`);
}
if (sess.status !== "idle") throw new Error(`late agent_end should leave session idle, got ${sess.status}`);

console.log("pi error teardown assertions passed");

export {};
