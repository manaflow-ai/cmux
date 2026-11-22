import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { readLines } from "../adapters/lines";

const directory = process.argv[2];
if (!directory) throw new Error("missing startup fixture directory");
const mode = readFileSync(join(directory, "mode"), "utf8").trim();
appendFileSync(join(directory, "processes.jsonl"), JSON.stringify({ pid: process.pid, mode }) + "\n");
// Startup cleanup must not depend on the agent cooperating with SIGTERM.
process.on("SIGTERM", () => {});
const keepAlive = setInterval(() => {}, 1_000);
await readLines(Bun.stdin.stream(), (line) => {
  const request = JSON.parse(line);
  if (request.id === undefined) return;
  if (request.method === "session/new" && mode === "dispose-session") {
    writeFileSync(join(directory, "session-ready"), "");
    const release = setInterval(() => {
      if (!existsSync(join(directory, "session-release"))) return;
      clearInterval(release);
      console.log(JSON.stringify({ jsonrpc: "2.0", id: request.id,
        result: { sessionId: `fixture-${process.pid}` } }));
    }, 10);
    return;
  }
  const stage = request.method === "initialize" ? "initialize" : request.method === "session/new" ? "session" : "";
  if (stage && mode === `hang-${stage}`) return;
  if (stage && mode === `reject-${stage}`) {
    console.log(JSON.stringify({ jsonrpc: "2.0", id: request.id,
      error: { code: -32603, message: `fixture ${stage} rejected` } }));
    return;
  }
  let result: unknown = {};
  if (request.method === "initialize") result = { protocolVersion: 1, agentCapabilities: {} };
  if (request.method === "session/new") result = { sessionId: `fixture-${process.pid}` };
  if (request.method === "session/prompt") {
    appendFileSync(join(directory, "prompts.jsonl"), JSON.stringify(request.params) + "\n");
    result = { stopReason: "end_turn" };
  }
  console.log(JSON.stringify({ jsonrpc: "2.0", id: request.id, result }));
  if (request.method === "session/new") {
    console.log(JSON.stringify({ jsonrpc: "2.0", method: "session/update", params: {
      sessionId: `fixture-${process.pid}`, update: {
        sessionUpdate: "available_commands_update", availableCommands: [{ name: "fixture", description: "Fixture command" }],
      },
    } }));
  }
});
clearInterval(keepAlive);
