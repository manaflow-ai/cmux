import { claudeHandleLineForTest, claudeProcessCloseForTest } from "../adapters/claude";
import type { AgentEvent, SessionCtx, SessionStatus } from "../types";

function makeSession(activeTurn: boolean): { sess: SessionCtx; events: AgentEvent[] } {
  const events: AgentEvent[] = [];
  const sess: SessionCtx = {
    id: "claude-test",
    provider: "claude",
    cwd: "/tmp",
    title: "claude test",
    autoApprove: true,
    startOptions: {},
    status: activeTurn ? "running" : "idle",
    events,
    internal: {
      claude: {
        nextRequest: 1,
        pending: new Map(),
        model: "claude-sonnet-5",
        modelChoices: [{ value: "claude-sonnet-5", label: "Claude Sonnet 5" }],
        modelMeta: new Map(),
        permissionMode: "acceptEdits",
        thinking: "0",
        effort: "medium",
        fastMode: false,
        context: "200k",
        initialApplied: true,
        commands: [],
        activeTurns: activeTurn ? 1 : 0,
        activeGenerations: activeTurn ? [1] : [],
      },
    },
    emit(evt) {
      events.push(evt);
    },
    setStatus(status: SessionStatus) {
      this.status = status;
    },
  };
  return { sess, events };
}

{
  const { sess, events } = makeSession(true);
  claudeHandleLineForTest(sess, JSON.stringify({ type: "result", subtype: "success", duration_ms: 1200, total_cost_usd: 0.012, num_turns: 1 }));
  claudeProcessCloseForTest(sess);
  const done = events.filter((evt) => evt.kind === "done");
  const errors = events.filter((evt) => evt.kind === "error");
  if (done.length !== 1) throw new Error(`normal result should emit exactly one done, got ${JSON.stringify(events)}`);
  if (errors.length) throw new Error(`normal close after result should not emit an error, got ${JSON.stringify(events)}`);
  if (sess.status !== "idle") throw new Error(`normal close should leave session idle, got ${sess.status}`);
  if ((sess.internal.claude as any).activeTurns) throw new Error("normal result should clear claude active turn");
}

{
  const { sess, events } = makeSession(true);
  claudeProcessCloseForTest(sess);
  const done = events.filter((evt) => evt.kind === "done");
  const errors = events.filter((evt) => evt.kind === "error");
  if (done.length !== 1) throw new Error(`mid-turn exit should emit exactly one done, got ${JSON.stringify(events)}`);
  if (!errors.some((evt) => /claude process exited mid-turn/.test(evt.message))) {
    throw new Error(`mid-turn exit should report the crash, got ${JSON.stringify(events)}`);
  }
  claudeProcessCloseForTest(sess);
  if (events.filter((evt) => evt.kind === "done").length !== 1) {
    throw new Error(`repeated close should not duplicate done, got ${JSON.stringify(events)}`);
  }
  if (sess.status !== "idle") throw new Error(`mid-turn exit should leave session idle, got ${sess.status}`);
}

{
  const { sess, events } = makeSession(true);
  const st = sess.internal.claude as any;
  st.activeTurns = 3;
  st.activeGenerations = [10, 11, 12];
  claudeProcessCloseForTest(sess);
  const done = events.filter((evt) => evt.kind === "done");
  const errors = events.filter((evt) => evt.kind === "error");
  const generations = done.map((evt) => (evt as any).generation).join("|");
  if (done.length !== 3) throw new Error(`queued close should emit one done per generation, got ${JSON.stringify(events)}`);
  if (errors.length !== 3) throw new Error(`queued close should emit one error per unfinished generation, got ${JSON.stringify(events)}`);
  if (generations !== "10|11|12") throw new Error(`queued close should preserve generation order, got ${generations}`);
  if (st.activeTurns || st.activeGenerations.length) throw new Error("queued close should clear all claude active turns");
}

console.log("claude active-turn assertions passed");

export {};
