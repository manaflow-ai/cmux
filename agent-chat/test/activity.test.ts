import { activityIndicatorState, activityTailKey } from "../src/activity";
import type { Block } from "../src/session";

function expectState(name: string, status: string | undefined, blocks: Block[], show: boolean, label: "Thinking" | "Reasoning") {
  const got = activityIndicatorState(status, blocks);
  if (got.show !== show || got.label !== label) {
    throw new Error(`${name}: expected ${JSON.stringify({ show, label })}, got ${JSON.stringify(got)}`);
  }
}

expectState("idle hides", "idle", [], false, "Thinking");
expectState("running after user shows", "running", [{ kind: "user", text: "hi" }], true, "Thinking");
expectState("assistant streaming hides", "running", [{ kind: "assistant", text: "hello", open: true }], false, "Thinking");
expectState("thinking streaming reasons", "running", [{ kind: "thinking", text: "trace", open: true }], true, "Reasoning");
expectState("tool running hides", "running", [{ kind: "tool", toolId: "1", name: "read", status: "running" }], false, "Thinking");
expectState("after tool result shows", "running", [{ kind: "tool", toolId: "1", name: "read", status: "ok", out: "done" }], true, "Thinking");
expectState("closed assistant while still running shows", "running", [{ kind: "assistant", text: "done", open: false }], true, "Thinking");

const reasoningA: Block[] = [{ kind: "thinking", text: "a", open: true }];
const reasoningB: Block[] = [{ kind: "thinking", text: "a longer streamed thought", open: true }];
if (activityTailKey(reasoningA) !== activityTailKey(reasoningB)) {
  throw new Error("reasoning activity key should not reset on every text delta");
}

console.log("activity indicator state: OK");
