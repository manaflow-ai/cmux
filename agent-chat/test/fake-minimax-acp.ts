import { createInterface } from "node:readline";

const modelIndex = Bun.argv.indexOf("--model");
const model = modelIndex < 0 ? "" : Bun.argv[modelIndex + 1];
const prompts: unknown[] = [];
const send = (message: unknown) => process.stdout.write(`${JSON.stringify(message)}\n`);
for await (const line of createInterface({ input: process.stdin })) {
  const message = JSON.parse(line);
  if (message.method === "initialize") {
    send({ jsonrpc: "2.0", id: message.id, result: { protocolVersion: 1 } });
  } else if (message.method === "session/new") {
    send({ jsonrpc: "2.0", id: message.id, result: {
      sessionId: "offline-minimax",
      models: {
        currentModelId: model,
        availableModels: ["MiniMax-M2.7", "MiniMax-M3", "MiniMax-M3.1-Flash"].map((id) => ({ modelId: id, name: id })),
      },
      configOptions: [{ id: "effort", type: "select", name: "Effort", currentValue: "max", options: [{ value: "max", name: "max" }] }],
    } });
  } else if (message.method === "session/prompt") {
    prompts.push(message.params);
    send({ jsonrpc: "2.0", method: "session/update", params: { update: {
      sessionUpdate: "agent_message_chunk",
      content: { type: "text", text: JSON.stringify({ model, prompts }) },
    } } });
    send({ jsonrpc: "2.0", id: message.id, result: { stopReason: "end_turn" } });
  } else if (message.id != null) {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
  }
}
