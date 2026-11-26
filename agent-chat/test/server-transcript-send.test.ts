// A transcript chat view dispatches prompts through the same adapter as any
// other session, and that adapter can reject: the Pi adapter throws when its
// process is replaced during startup, and any adapter throws when a spawn
// fails. The transcript branch of sendPrompt has no turn generation to unwind,
// so this only checks that the failure reaches the user instead of surfacing
// as an unhandled rejection.
import { emitDoneAfterFilesForTest, emitSessionEventForTest, sendPromptForTest } from "../server";
import type { Adapter, AgentEvent, SessionStatus } from "../types";

function assert(cond: unknown, msg: string): asserts cond {
  if (!cond) throw new Error(msg);
}

const unhandled: unknown[] = [];
const onUnhandled = (reason: unknown) => {
  unhandled.push(reason);
};
process.on("unhandledRejection", onUnhandled);

const adapter = {
  capabilities: { options: [] },
  async send() {
    throw new Error("pi process changed during startup");
  },
  stop() {},
  dispose() {},
  setOption: async () => {},
} as unknown as Adapter;

const events: AgentEvent[] = [];
const sess = {
  id: "transcript-send-rejection",
  provider: "pi",
  cwd: "/tmp",
  title: "transcript send rejection",
  autoApprove: true,
  startOptions: {},
  status: "idle" as SessionStatus,
  events,
  internal: {},
  adapter,
  sockets: new Set(),
  createdAt: Date.now(),
  transcript: { agent: {} as never, path: "/tmp/transcript.jsonl" },
  emit(evt: AgentEvent) {
    if (evt.kind === "done") emitDoneAfterFilesForTest(this as never, evt);
    else emitSessionEventForTest(this as never, evt);
  },
  setStatus(status: SessionStatus) {
    this.status = status;
  },
};

sendPromptForTest(sess as never, "prompt that cannot be delivered");
// Two turns of the microtask queue: one for the rejection, one for the handler.
await Promise.resolve();
await Promise.resolve();
// An unhandledRejection listener fires on a macrotask, not a microtask.
await new Promise((resolve) => setTimeout(resolve, 0));

const error = events.find((evt) => evt.kind === "error") as Extract<AgentEvent, { kind: "error" }> | undefined;
assert(error, `a rejected transcript send must emit an error event: ${JSON.stringify(events)}`);
// safeReason maps anything outside its allow-list to "unexpected error", so
// the contract is the sanitized send message the other two call sites emit,
// not the adapter's own text.
assert(
  error.message === "Failed to send message: unexpected error",
  `the error event should carry the sanitized send message: ${JSON.stringify(error)}`,
);
assert(
  unhandled.length === 0,
  `a rejected transcript send must not leave an unhandled rejection: ${String(unhandled[0])}`,
);

process.off("unhandledRejection", onUnhandled);
console.log("transcript send rejection assertions passed");

export {};
