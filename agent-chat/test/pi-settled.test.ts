import { piHandleLineForTest, piNextSendTypeForTest, piAdapter } from "../adapters/pi";
import type { AgentEvent, SessionCtx, SessionStatus } from "../types";

const events: AgentEvent[] = [];
const sess: SessionCtx = {
  id: "pi-settled-test",
  provider: "pi",
  cwd: "/tmp",
  title: "pi settled test",
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
      activeGeneration: 7,
    },
  },
  emit(evt) {
    events.push(evt);
  },
  setStatus(status: SessionStatus) {
    this.status = status;
  },
};

function send(event: Record<string, unknown>) {
  piHandleLineForTest(sess, JSON.stringify(event));
}

function doneEvents() {
  return events.filter((evt) => evt.kind === "done");
}

send({ type: "agent_start" });
send({ type: "agent_end", willRetry: true });
if (sess.status !== "running") throw new Error(`retrying Pi run should remain running, got ${sess.status}`);
if (doneEvents().length !== 0) throw new Error("agent_end with a retry should not finalize the turn");
if (piNextSendTypeForTest(sess) !== "steer") throw new Error("message before settlement should steer the active turn");
if ((piAdapter as any).attributionMode(sess) !== "current-turn") {
  throw new Error("message before settlement should use current-turn attribution");
}

send({ type: "agent_start" });
send({ type: "agent_end", willRetry: false });
if (sess.status !== "running") throw new Error(`unsettled Pi run should remain running, got ${sess.status}`);
if (doneEvents().length !== 0) throw new Error("agent_end before settlement should not emit done");

send({ type: "agent_settled" });
if (sess.status !== "idle") throw new Error(`settled Pi run should become idle, got ${sess.status}`);
const done = doneEvents();
if (done.length !== 1) throw new Error(`settlement should emit exactly one done, got ${JSON.stringify(events)}`);
if ((done[0] as AgentEvent & { generation?: number }).generation !== 7) {
  throw new Error(`settlement should preserve generation 7, got ${JSON.stringify(done[0])}`);
}
if (piNextSendTypeForTest(sess) !== "prompt") throw new Error("message after settlement should start a new prompt");

send({ type: "agent_settled" });
if (doneEvents().length !== 1) throw new Error("duplicate settlement should not emit another done");

console.log("pi settled lifecycle assertions passed");

export {};
