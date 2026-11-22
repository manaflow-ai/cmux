import { piAdapter, piHandleLineForTest } from "../adapters/pi";
import type { AgentEvent, SessionCtx, SessionStatus } from "../types";

type Write = { proc: string; message: any };

async function flush() {
  for (let i = 0; i < 8; i++) await Promise.resolve();
}

function fakeProc(name: string, writes: Write[]) {
  return {
    exitCode: null,
    killed: false,
    stdin: {
      write(data: string) {
        writes.push({ proc: name, message: JSON.parse(data) });
        return data.length;
      },
      flush() {},
    },
    kill() {},
  } as any;
}

const writes: Write[] = [];
const firstProc = fakeProc("first", writes);
const replacementProc = fakeProc("replacement", writes);
const events: AgentEvent[] = [];
const sess: SessionCtx = {
  id: "pi-startup-replacement",
  provider: "pi",
  cwd: "/tmp",
  title: "pi startup replacement",
  autoApprove: true,
  startOptions: { model: "p/m" },
  status: "idle",
  events,
  internal: {
    pi: {
      proc: firstProc,
      nextId: 1,
      pending: new Map(),
      model: "p/m",
      modelChoices: [{ value: "p/m", label: "Model", efforts: [], defaultEffort: "" }],
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

const send = piAdapter.send(sess, "PROMPT");
const firstSetup = writes.filter((write) => write.proc === "first").map((write) => write.message);
if (firstSetup.length !== 1 || firstSetup[0].type !== "set_model") {
  throw new Error(`initial setup must set the requested model: ${JSON.stringify(firstSetup)}`);
}

piHandleLineForTest(sess, JSON.stringify({
  type: "response",
  id: firstSetup[0].id,
  success: true,
  data: {},
}));
await flush();

const stateRequest = writes.find((write) => write.proc === "first" && write.message.type === "get_state");
if (!stateRequest) throw new Error(`initial setup must capture state: ${JSON.stringify(writes)}`);

// The response and process close happen in the same job. No pending request
// remains to reject when the close is observed.
piHandleLineForTest(sess, JSON.stringify({
  type: "response",
  id: stateRequest.message.id,
  success: true,
  data: { sessionFile: "/tmp/first-session.jsonl" },
}));
const st = sess.internal.pi as any;
st.proc = replacementProc;
st.initialApplied = false;
st.initialApplying = undefined;

await flush();

const replacementWrites = writes
  .filter((write) => write.proc === "replacement")
  .map((write) => write.message);
const replacementSetup = replacementWrites.findIndex((message) => message.type === "set_model");
const replacementPrompt = replacementWrites.findIndex((message) => message.type === "prompt");
if (replacementSetup < 0 || (replacementPrompt >= 0 && replacementPrompt < replacementSetup)) {
  throw new Error(`replacement must receive set_model before its prompt: ${JSON.stringify(replacementWrites)}`);
}

piHandleLineForTest(sess, JSON.stringify({
  type: "response",
  id: replacementWrites[replacementSetup].id,
  success: true,
  data: {},
}));
await flush();

const replacementState = writes.find((write) => write.proc === "replacement" && write.message.type === "get_state");
if (!replacementState) throw new Error(`replacement setup must capture state: ${JSON.stringify(writes)}`);
piHandleLineForTest(sess, JSON.stringify({
  type: "response",
  id: replacementState.message.id,
  success: true,
  data: { sessionFile: "/tmp/replacement-session.jsonl" },
}));
await send;

const finalReplacementWrites = writes.filter((write) => write.proc === "replacement").map((write) => write.message);
const prompt = finalReplacementWrites.findIndex((message) => message.type === "prompt");
if (prompt < 0 || prompt < replacementSetup) {
  throw new Error(`replacement prompt must follow setup: ${JSON.stringify(finalReplacementWrites)}`);
}

console.log("pi startup replacement ordering assertion passed");

export {};
