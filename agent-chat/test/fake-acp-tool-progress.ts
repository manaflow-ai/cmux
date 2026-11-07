import { createInterface } from "node:readline";

const send = (msg: unknown) => process.stdout.write(`${JSON.stringify(msg)}\n`);

for await (const line of createInterface({ input: process.stdin })) {
  if (!line.trim()) continue;
  const msg = JSON.parse(line);
  if (msg.method === "initialize") {
    send({ jsonrpc: "2.0", id: msg.id, result: { protocolVersion: 1 } });
  } else if (msg.method === "session/new") {
    send({ jsonrpc: "2.0", id: msg.id, result: { sessionId: "fake-tool-progress" } });
  } else if (msg.method === "session/prompt") {
    const notify = (update: unknown) => send({ jsonrpc: "2.0", method: "session/update", params: { update } });
    notify({
      sessionUpdate: "tool_call",
      toolCallId: "progress",
      title: "Long task",
      locations: [{ path: "src/work.ts" }],
    });
    notify({
      sessionUpdate: "tool_call_update",
      toolCallId: "progress",
      status: "in_progress",
      content: [{ type: "content", content: { type: "text", text: "step 1" } }],
    });
    notify({
      sessionUpdate: "tool_call_update",
      toolCallId: "progress",
      status: "in_progress",
      title: "Long task (still running)",
      content: [{ type: "diff", path: "src/work.ts", oldText: "old line", newText: "new line" }],
    });
    notify({
      sessionUpdate: "tool_call_update",
      toolCallId: "progress",
      status: "completed",
      content: [{ type: "terminal", terminalId: "term-42" }],
    });
    notify({
      sessionUpdate: "tool_call",
      toolCallId: "failure",
      title: "Failing task",
      locations: [{ path: "src/fail.ts" }],
    });
    notify({
      sessionUpdate: "tool_call_update",
      toolCallId: "failure",
      status: "in_progress",
      content: [{ type: "content", content: { type: "text", text: "checking" } }],
    });
    notify({
      sessionUpdate: "tool_call_update",
      toolCallId: "failure",
      status: "failed",
      content: [{ type: "content", content: { type: "text", text: "exit 1" } }],
    });
    send({ jsonrpc: "2.0", id: msg.id, result: { stopReason: "end_turn" } });
  }
}
