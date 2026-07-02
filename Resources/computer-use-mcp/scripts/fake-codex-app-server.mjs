#!/usr/bin/env node
// Test stub for elicitation-smoke.mjs: a fake `codex app-server` (newline
// JSON-RPC on stdio) whose computer-use tool call triggers an approval
// elicitation, then reports which action came back. Only `app-server` is
// supported; anything else exits nonzero like an unknown subcommand would.
import { createInterface } from "node:readline";
import process from "node:process";

if (process.argv[2] !== "app-server") {
  console.error(`fake-codex: unknown subcommand ${process.argv[2]}`);
  process.exit(2);
}

const send = (message) => process.stdout.write(`${JSON.stringify(message)}\n`);
let pendingToolCallId = null;

createInterface({ input: process.stdin }).on("line", (line) => {
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    return;
  }
  if (message.method === "initialize") {
    send({ id: message.id, result: { userAgent: "fake-codex/0.0.1" } });
    return;
  }
  if (message.method === "thread/start") {
    send({ id: message.id, result: { thread: { id: "thread-test" } } });
    return;
  }
  if (message.method === "mcpServer/tool/call") {
    pendingToolCallId = message.id;
    send({
      id: "elicit-1",
      method: "mcpServer/elicitation/request",
      params: {
        threadId: "thread-test",
        serverName: "computer-use",
        message: "Allow Codex to use TestApp?",
        mode: "form",
        requestedSchema: { type: "object", properties: {} },
      },
    });
    return;
  }
  if (message.id === "elicit-1" && message.method === undefined) {
    const action = message.result?.action ?? "missing";
    send({
      id: pendingToolCallId,
      result: {
        content: [{ type: "text", text: `elicitation:${action}` }],
        isError: action !== "accept",
      },
    });
  }
});
