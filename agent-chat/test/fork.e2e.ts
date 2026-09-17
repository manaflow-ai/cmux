// Fork coverage: create a pi session, fork it, verify source and fork provider
// contexts both retain the pre-fork exchange.
const PORT = Number(process.env.CMUX_AGENT_UI_PORT ?? 7739);
const TIMEOUT_MS = Number(process.env.E2E_TIMEOUT_MS ?? 180_000);
const cwd = `${import.meta.dir}/../scratch`;

const ws = new WebSocket(`ws://127.0.0.1:${PORT}/ws`);
let opened = false;
let sessionId = "";
let forkId = "";
let history: any[] = [];
let text = "";
let done = 0;
let forkText = "";
let forkDone = 0;
const errors: string[] = [];

const waitFor = <T>(name: string, pred: () => T | false | null | undefined): Promise<T> =>
  new Promise((resolve, reject) => {
    const started = Date.now();
    const tick = () => {
      const value = pred();
      if (value) return resolve(value);
      if (Date.now() - started > TIMEOUT_MS) return reject(new Error(`timeout waiting for ${name}`));
      setTimeout(tick, 40);
    };
    tick();
  });

const send = (obj: unknown) => ws.send(JSON.stringify(obj));

ws.onopen = () => {
  opened = true;
  send({
    op: "start",
    provider: "pi",
    cwd,
    autoApprove: true,
    prompt: "Reply with exactly the word PONG and nothing else. Do not use tools.",
  });
};
ws.onmessage = (e) => {
  const msg = JSON.parse(String(e.data));
  if (msg.kind === "session-created") sessionId = msg.session.id;
  if (msg.kind === "session-forked") forkId = msg.session.id;
  if (msg.kind === "history" && msg.sessionId === forkId) history = msg.events ?? [];
  if (msg.kind === "event") {
    const evt = msg.evt;
    if (evt.kind === "error") errors.push(String(evt.message ?? ""));
    if (msg.sessionId === sessionId) {
      if (evt.kind === "delta" || evt.kind === "assistant") text += evt.text;
      if (evt.kind === "done") done++;
    }
    if (msg.sessionId === forkId) {
      if (evt.kind === "delta" || evt.kind === "assistant") forkText += evt.text;
      if (evt.kind === "done") forkDone++;
    }
  }
};

try {
  await waitFor("open", () => opened);
  await waitFor("source done", () => done >= 1);
  if (!text.toUpperCase().includes("PONG")) throw new Error(`source did not reply PONG: ${JSON.stringify(text.slice(0, 200))}`);
  send({ op: "fork", sessionId });
  await waitFor("fork", () => forkId);
  text = "";
  const sourceDoneBeforeRecall = done;
  send({
    op: "send",
    sessionId,
    prompt: "What exact word did I ask you to reply with earlier? Reply with only that word.",
  });
  await waitFor("source recall done", () => done > sourceDoneBeforeRecall);
  if (!text.toUpperCase().includes("PONG")) {
    throw new Error(`source context was not intact after fork: ${JSON.stringify(text.slice(0, 200))}`);
  }

  send({ op: "subscribe", sessionId: forkId });
  await waitFor("fork history", () => history.length ? history : false);
  if (!history.some((e) => e.kind === "user")) throw new Error("fork history missing user event");
  if (!history.some((e) => e.kind === "delta" || e.kind === "assistant" || e.kind === "done")) {
    throw new Error("fork history missing source assistant turn");
  }
  forkText = "";
  const forkDoneBeforeRecall = forkDone;
  send({
    op: "send",
    sessionId: forkId,
    prompt: "What exact word did I ask you to reply with earlier? Reply with only that word.",
  });
  await waitFor("fork recall done", () => forkDone > forkDoneBeforeRecall);
  if (!forkText.toUpperCase().includes("PONG")) {
    throw new Error(`fork context did not include source history: ${JSON.stringify(forkText.slice(0, 200))}`);
  }
  console.log("pi fork: OK");
} finally {
  ws.close();
}

if (errors.length) {
  console.error(errors.join("\n"));
  process.exit(1);
}
