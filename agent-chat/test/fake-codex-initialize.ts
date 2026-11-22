import { appendFileSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { readLines } from "../adapters/lines";

const directory = process.env.CMUX_CODEX_INIT_TEST_DIRECTORY;
if (!directory) throw new Error("missing initialization fixture directory");
const mode = readFileSync(join(directory, "mode"), "utf8").trim();
appendFileSync(join(directory, "processes.jsonl"), JSON.stringify({ pid: process.pid, mode }) + "\n");

// A rejected initialization need not make an app-server exit voluntarily.
// Ignore a graceful signal too, so cleanup cannot hang waiting for cooperation.
process.on("SIGTERM", () => {});
const keepAlive = setInterval(() => {}, 1_000);
await readLines(Bun.stdin.stream(), (line) => {
  const request = JSON.parse(line);
  if (request.id === undefined) return;
  if (request.method === "initialize" && mode === "hang") return;
  let result: unknown = {};
  if (request.method === "initialize" && mode === "reject") {
    console.log(JSON.stringify({ jsonrpc: "2.0", id: request.id,
      error: { code: -32603, message: "fixture initialization rejected" } }));
    return;
  }
  if (request.method === "model/list") {
    result = { data: [{ id: "fixture-model", model: "fixture-model", displayName: "Fixture model" }], nextCursor: null };
  }
  if (request.method === "collaborationMode/list") {
    result = { data: [{ mode: "default", name: "Default" }] };
  }
  console.log(JSON.stringify({ jsonrpc: "2.0", id: request.id, result }));
});
clearInterval(keepAlive);
