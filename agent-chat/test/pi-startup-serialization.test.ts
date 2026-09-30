import { piAdapter, piHandleLineForTest } from "../adapters/pi";
import type { AgentEvent, SessionCtx, SessionStatus } from "../types";

const writes: string[] = [];
const proc = {
  exitCode: null,
  killed: false,
  stdin: {
    write(data: string) {
      writes.push(data);
      return data.length;
    },
    flush() {},
  },
} as any;
const events: AgentEvent[] = [];
const sess: SessionCtx = {
  id: "pi-startup-serialization",
  provider: "pi",
  cwd: "/tmp",
  title: "pi startup serialization",
  autoApprove: true,
  startOptions: {},
  status: "idle",
  events,
  internal: {
    pi: {
      proc,
      nextId: 1,
      pending: new Map(),
      model: "provider/model",
      modelChoices: [{ value: "provider/model", label: "Model", efforts: [], defaultEffort: "" }],
      thinking: "",
      commands: [{ name: "help" }],
      initialApplied: false,
      activeTurn: false,
    },
  },
  emit(evt) {
    events.push(evt);
  },
  setStatus(status: SessionStatus) {
    this.status = status;
  },
};

const first = piAdapter.send(sess, "first prompt");
const second = piAdapter.send(sess, "second prompt");
await Promise.resolve();
await Promise.resolve();

const setup = writes.map((line) => JSON.parse(line));
if (setup.length !== 1 || setup[0].type !== "get_state") {
  throw new Error(`concurrent sends must share initial setup: ${JSON.stringify(setup)}`);
}

// Hold the first setup RPC open. The second send must not write its prompt
// until this response releases the shared initialization promise.
piHandleLineForTest(sess, JSON.stringify({
  type: "response",
  id: setup[0].id,
  success: true,
  data: { sessionFile: "/tmp/pi-session.jsonl" },
}));
await Promise.all([first, second]);

const messages = writes.map((line) => JSON.parse(line));
const prompts = messages.filter((msg) => msg.type === "prompt" || msg.type === "steer");
if (prompts.length !== 2 || prompts[0].message !== "first prompt" || prompts[1].message !== "second prompt") {
  throw new Error(`both prompts must be delivered once after setup: ${JSON.stringify(messages)}`);
}
if (prompts[0].type !== "prompt" || prompts[1].type !== "steer") {
  throw new Error(`the second prompt should target the active turn: ${JSON.stringify(prompts)}`);
}

console.log("pi startup serialization assertions passed");

export {};
