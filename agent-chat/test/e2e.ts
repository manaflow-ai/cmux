// End-to-end smoke: for each provider, start a session over WS, send a
// prompt, and assert we see streamed/final assistant text plus a done event.
// Usage: bun test/e2e.ts [provider ...]
const PORT = Number(process.env.CMUX_AGENT_UI_PORT ?? 7739);
const providersToTest = Bun.argv.slice(2).length
  ? Bun.argv.slice(2)
  : ["claude", "codex", "opencode", "pi", "gemini"];

const TIMEOUT_MS = Number(process.env.E2E_TIMEOUT_MS ?? 180_000);

async function testProvider(provider: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${PORT}/ws`);
    let text = "";
    let sessionId: string | null = null;
    let errors: string[] = [];
    const timer = setTimeout(() => {
      ws.close();
      reject(new Error(`${provider}: timeout after ${TIMEOUT_MS}ms; text so far: ${JSON.stringify(text.slice(0, 200))}; errors: ${errors.join("; ")}`));
    }, TIMEOUT_MS);

    ws.onopen = () => {
      ws.send(JSON.stringify({
        op: "start",
        provider,
        cwd: `${import.meta.dir}/../scratch`,
        autoApprove: true,
        prompt: "Reply with exactly the word PONG and nothing else. Do not use any tools.",
      }));
    };
    ws.onmessage = (e) => {
      const msg = JSON.parse(String(e.data));
      if (msg.kind === "session-created") sessionId = msg.session.id;
      if (msg.kind !== "event" || msg.sessionId !== sessionId) return;
      const evt = msg.evt;
      if (evt.kind === "delta" || evt.kind === "assistant") text += evt.text;
      if (evt.kind === "error") errors.push(evt.message);
      if (evt.kind === "done") {
        clearTimeout(timer);
        ws.close();
        if (text.toUpperCase().includes("PONG")) {
          resolve(`${provider}: OK (${JSON.stringify(text.trim().slice(0, 60))})`);
        } else {
          reject(new Error(`${provider}: done but no PONG; text=${JSON.stringify(text.slice(0, 200))}; errors: ${errors.join("; ")}`));
        }
      }
    };
    ws.onerror = () => {
      clearTimeout(timer);
      reject(new Error(`${provider}: websocket error (is the server running on :${PORT}?)`));
    };
  });
}

let failed = 0;
for (const p of providersToTest) {
  try {
    console.log(await testProvider(p));
  } catch (err) {
    failed++;
    console.error(String(err));
  }
}
process.exit(failed ? 1 : 0);
