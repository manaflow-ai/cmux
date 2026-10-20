import { createInterface } from "node:readline";

const send = (msg: unknown) => {
  process.stdout.write(`${JSON.stringify(msg)}\n`);
};

for await (const line of createInterface({ input: process.stdin })) {
  if (!line.trim()) continue;
  const msg = JSON.parse(line);
  if (msg.method === "initialize") {
    send({ jsonrpc: "2.0", id: msg.id, result: { protocolVersion: 1 } });
  } else if (msg.method === "session/new") {
    send({ jsonrpc: "2.0", id: msg.id, result: { sessionId: "fake-tool-detail" } });
  } else if (msg.method === "session/prompt") {
    const notify = (update: unknown) => send({ jsonrpc: "2.0", method: "session/update", params: { update } });
    notify({
      sessionUpdate: "tool_call",
      toolCallId: "located",
      title: "Edit files",
      rawInput: { command: "edit" },
      locations: [{ path: "src/one.ts", line: 4 }, { path: "src/two.ts" }],
    });
    notify({
      sessionUpdate: "tool_call",
      toolCallId: "raw-input",
      title: "Inspect files",
      rawInput: { command: "cat README.md" },
    });
    notify({
      sessionUpdate: "tool_call_update",
      toolCallId: "new-file",
      status: "completed",
      content: [{ type: "diff", path: "src/new.ts", oldText: null, newText: "one\ntwo" }],
    });
    notify({
      sessionUpdate: "tool_call_update",
      toolCallId: "changed-file",
      status: "completed",
      content: [{ type: "diff", path: "src/changed.ts", oldText: "old", newText: "new\nlines" }],
    });
    notify({
      sessionUpdate: "tool_call_update",
      toolCallId: "mixed",
      status: "completed",
      content: [
        { type: "content", content: { type: "text", text: "text output" } },
        { type: "diff", path: "src/mixed.ts", oldText: "old", newText: "new" },
        { type: "terminal", terminalId: "term-42" },
      ],
    });
    send({ jsonrpc: "2.0", id: msg.id, result: { stopReason: "end_turn" } });
  } else if (msg.id != null) {
    send({ jsonrpc: "2.0", id: msg.id, result: {} });
  }
}
