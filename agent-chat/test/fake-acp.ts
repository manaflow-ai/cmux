import { appendFile } from "node:fs/promises";
import { createInterface } from "node:readline";

const modelFlag = Bun.argv.findIndex((arg) => arg === "--model");
const model = modelFlag >= 0 ? Bun.argv[modelFlag + 1] ?? "" : "";
const log = process.env.FAKE_ACP_MODEL_LOG;
if (log) await appendFile(log, `${model}\n`);

const rl = createInterface({ input: process.stdin });
const send = (msg: unknown) => {
  process.stdout.write(`${JSON.stringify(msg)}\n`);
};

for await (const line of rl) {
  if (!line.trim()) continue;
  const msg = JSON.parse(line);
  if (msg.method === "initialize") {
    send({ jsonrpc: "2.0", id: msg.id, result: { protocolVersion: 1 } });
  } else if (msg.method === "session/new") {
    send({ jsonrpc: "2.0", id: msg.id, result: { sessionId: `fake-${model || "default"}` } });
  } else if (msg.method === "session/prompt") {
    send({
      jsonrpc: "2.0",
      method: "session/update",
      params: { update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "OK" } } },
    });
    send({ jsonrpc: "2.0", id: msg.id, result: { stopReason: "end_turn" } });
  } else if (msg.id != null) {
    send({ jsonrpc: "2.0", id: msg.id, result: {} });
  }
}
