const PORT = Number(process.env.CMUX_AGENT_UI_PORT ?? 7739);
const TIMEOUT_MS = Number(process.env.E2E_TIMEOUT_MS ?? 30_000);

export {};

const ws = new WebSocket(`ws://127.0.0.1:${PORT}/ws`);
let opened = false;
let forkError = "";
let diffError = "";

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

ws.onopen = () => {
  opened = true;
  ws.send(JSON.stringify({ op: "fork", sessionId: "missing-session" }));
  ws.send(JSON.stringify({ op: "get-file-diff", sessionId: "missing-session", path: "tracked.txt" }));
};
ws.onmessage = (e) => {
  const msg = JSON.parse(String(e.data));
  if (msg.kind === "error" && msg.op === "fork") forkError = String(msg.message ?? "");
  if (msg.kind === "error" && msg.op === "get-file-diff") diffError = String(msg.message ?? "");
};

try {
  await waitFor("open", () => opened);
  await waitFor("fork op error", () => forkError);
  if (!/no session/i.test(forkError)) throw new Error(`unexpected fork error: ${forkError}`);
  await waitFor("diff op error", () => diffError);
  if (!/failed to load diff/i.test(diffError) || !/no session/i.test(diffError)) {
    throw new Error(`unexpected diff error: ${diffError}`);
  }
  console.log("fork failure: OK");
} finally {
  ws.close();
}
