import { createInterface } from "node:readline";

const send = (msg: unknown) => {
  process.stdout.write(`${JSON.stringify(msg)}\n`);
};

const longContent = "x".repeat(350);

for await (const line of createInterface({ input: process.stdin })) {
  if (!line.trim()) continue;
  const msg = JSON.parse(line);
  if (msg.method === "initialize") {
    send({ jsonrpc: "2.0", id: msg.id, result: { protocolVersion: 1 } });
  } else if (msg.method === "session/new") {
    send({ jsonrpc: "2.0", id: msg.id, result: { sessionId: "fake-plan" } });
  } else if (msg.method === "session/prompt") {
    const notify = (update: unknown) => send({ jsonrpc: "2.0", method: "session/update", params: { update } });
    notify({
      sessionUpdate: "plan",
      entries: [
        { content: "Inspect the repository", status: "pending", priority: "high" },
        { content: "Implement the change", status: "in_progress" },
        { content: longContent, status: "completed" },
        { content: "Unknown state stays visible", status: "waiting" },
      ],
    });
    notify({
      sessionUpdate: "plan",
      entries: [{ content: "Verify the change", status: "in_progress", priority: "medium" }],
    });
    notify({ sessionUpdate: "plan", entries: [] });
    notify({ sessionUpdate: "plan" });
    send({ jsonrpc: "2.0", id: msg.id, result: { stopReason: "end_turn" } });
  } else if (msg.id != null) {
    send({ jsonrpc: "2.0", id: msg.id, result: {} });
  }
}
