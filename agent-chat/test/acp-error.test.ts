import { strict as assert } from "node:assert";
import { makeAcpAdapter } from "../adapters/acp";
import type { AgentEvent, SessionCtx } from "../types";

const detail = "Failed to resolve provider: Configuration value not found: GOOSE_PROVIDER";
const cases = [
  { data: detail, expected: `Internal error: ${detail}` },
  { data: undefined, expected: "Internal error" },
  { data: "", expected: "Internal error" },
  { data: { reason: "bad session" }, expected: "Internal error" },
  { data: null, expected: "Internal error" },
  { data: 42, expected: "Internal error" },
];
for (const phase of ["initialize", "session/new", "session/prompt"]) {
  for (const { data, expected } of cases) {
    const error = { code: -32603, message: "Internal error", data };
    const script = `
      import { createInterface } from "node:readline";
      for await (const line of createInterface({ input: process.stdin })) {
        const msg = JSON.parse(line);
        const response = msg.method === ${JSON.stringify(phase)}
          ? { error: ${JSON.stringify(error)} }
          : { result: { protocolVersion: 1, sessionId: "test-session" } };
        console.log(JSON.stringify({ jsonrpc: "2.0", id: msg.id, ...response }));
      }
    `;
    const adapter = makeAcpAdapter({ id: "test", label: "test", adapter: "acp", cmd: [process.execPath, "-e", script] });
    const events: AgentEvent[] = [];
    const sess: SessionCtx = {
      id: "test", provider: "test", cwd: process.cwd(), title: "test",
      autoApprove: true, startOptions: {}, status: "idle", events, internal: {},
      emit(event) { events.push(event); },
      setStatus(status) { this.status = status; },
    };
    try {
      await adapter.send(sess, "hello");
      assert.deepEqual(events.filter(e => e.kind === "error"), [{ kind: "error", message: `Error: ${expected}` }]);
      assert.equal(events.filter(e => e.kind === "done").length, 1);
      assert.equal(sess.status, "idle");
      if (phase !== "session/prompt") {
        await assert.rejects(adapter.listOptions!(process.cwd()), { message: expected });
        await assert.rejects(adapter.listCommands!(process.cwd()), { message: expected });
      }
    } finally {
      adapter.dispose(sess);
    }
  }
}
console.log("ACP error diagnostics: startup, prompt, and catalogs passed");
