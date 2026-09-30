import { access, appendFile } from "node:fs/promises";
import { createInterface } from "node:readline";

const send = (msg: unknown) => {
  process.stdout.write(`${JSON.stringify(msg)}\n`);
};

async function waitForFile(path: string | undefined) {
  if (!path) return;
  while (true) {
    try {
      await access(path);
      return;
    } catch {
      await Bun.sleep(10);
    }
  }
}

function argument(name: string): string | undefined {
  const index = Bun.argv.indexOf(name);
  return index >= 0 ? Bun.argv[index + 1] : undefined;
}

const startupGate = argument("--startup-gate");
const startupReady = argument("--startup-ready");
const promptGate = argument("--prompt-gate");
const promptLog = argument("--prompt-log");
let promptCount = 0;

for await (const line of createInterface({ input: process.stdin })) {
  if (!line.trim()) continue;
  const msg = JSON.parse(line);
  if (msg.method === "initialize") {
    send({ jsonrpc: "2.0", id: msg.id, result: { protocolVersion: 1 } });
  } else if (msg.method === "session/new") {
    if (startupReady) await appendFile(startupReady, "ready\n");
    await waitForFile(startupGate);
    send({ jsonrpc: "2.0", id: msg.id, result: { sessionId: "fake-stop" } });
  } else if (msg.method === "session/prompt") {
    promptCount += 1;
    if (promptLog) await appendFile(promptLog, `${msg.params?.prompt?.[0]?.text ?? ""}\n`);
    if (promptCount === 1) await waitForFile(promptGate);
    send({ jsonrpc: "2.0", id: msg.id, result: { stopReason: "end_turn" } });
  }
}
