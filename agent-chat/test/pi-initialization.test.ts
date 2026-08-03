import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { piAdapter } from "../adapters/pi";
import type { AgentEvent, SessionCtx, SessionStatus } from "../types";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

const fixtureRoot = await mkdtemp(join(tmpdir(), "cmux-pi-initialization-"));
const fakePiPath = join(fixtureRoot, "pi");
const requestLogPath = join(fixtureRoot, "requests.jsonl");
const originalPath = process.env.PATH;
const originalLogPath = process.env.CMUX_PI_INITIALIZATION_TEST_LOG;
const timeline: string[] = [];
const events: AgentEvent[] = [];

await writeFile(fakePiPath, String.raw`#!/usr/bin/env bun
import { appendFileSync } from "node:fs";

const logPath = process.env.CMUX_PI_INITIALIZATION_TEST_LOG;
let buffer = "";
let firstStateRequest = null;

function respond(message) {
  let data = {};
  if (message.type === "get_state") {
    data = { sessionFile: "/tmp/pi-initialization-session.jsonl" };
  } else if (message.type === "get_available_models") {
    data = { models: [{ provider: "test", id: "model", name: "Test Model" }] };
  } else if (message.type === "get_commands") {
    data = { commands: [{ name: "help", description: "Help" }] };
  }
  process.stdout.write(JSON.stringify({ type: "response", id: message.id, success: true, data }) + "\n");
}

function handle(line) {
  if (!line.trim()) return;
  const message = JSON.parse(line);
  appendFileSync(logPath, JSON.stringify(message) + "\n");
  if (message.type === "get_state" && firstStateRequest === null) {
    firstStateRequest = message;
    setTimeout(() => {
      if (firstStateRequest !== null) {
        respond(firstStateRequest);
        firstStateRequest = null;
      }
    }, 250);
    return;
  }
  if (message.id !== undefined) respond(message);
}

for await (const chunk of Bun.stdin.stream()) {
  buffer += new TextDecoder().decode(chunk);
  let newline = buffer.indexOf("\n");
  while (newline >= 0) {
    handle(buffer.slice(0, newline));
    buffer = buffer.slice(newline + 1);
    newline = buffer.indexOf("\n");
  }
}
`);
await chmod(fakePiPath, 0o755);

const sess: SessionCtx = {
  id: "pi-initialization-test",
  provider: "pi",
  cwd: fixtureRoot,
  title: "Pi initialization test",
  autoApprove: true,
  startOptions: {},
  status: "idle",
  events,
  internal: {},
  emit(event) {
    events.push(event);
    timeline.push(event.kind);
  },
  setStatus(status: SessionStatus) {
    this.status = status;
    timeline.push(`status:${status}`);
  },
};

try {
  process.env.PATH = `${fixtureRoot}:${originalPath ?? ""}`;
  process.env.CMUX_PI_INITIALIZATION_TEST_LOG = requestLogPath;

  let timeout: ReturnType<typeof setTimeout> | undefined;
  try {
    await Promise.race([
      Promise.all([
        piAdapter.refreshOptions?.(sess),
        piAdapter.send(sess, "first prompt"),
      ]),
      new Promise<never>((_, reject) => {
        timeout = setTimeout(() => reject(new Error("concurrent Pi refresh/send did not settle")), 5_000);
      }),
    ]);
  } finally {
    clearTimeout(timeout);
  }

  const requests = (await readFile(requestLogPath, "utf8"))
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  const requestTypes = requests.map((request) => request.type as string);
  const count = (type: string) => requestTypes.filter((candidate) => candidate === type).length;

  assert(count("get_available_models") === 1, `initialization fetched models ${count("get_available_models")} times: ${requestTypes.join(" -> ")}`);
  assert(count("get_commands") === 1, `initialization fetched commands ${count("get_commands")} times: ${requestTypes.join(" -> ")}`);
  assert(events.filter((event) => event.kind === "options").length === 1, `initialization emitted duplicate option snapshots: ${timeline.join(" -> ")}`);

  const runningIndex = timeline.indexOf("status:running");
  assert(runningIndex >= 0, `first prompt was not dispatched: ${timeline.join(" -> ")}`);
  const lateInitializationEvents = timeline.slice(runningIndex + 1).filter((event) => event === "meta" || event === "options" || event === "commands");
  assert(lateInitializationEvents.length === 0, `initialization events arrived after the first prompt: ${timeline.join(" -> ")}`);
} finally {
  piAdapter.dispose(sess);
  if (originalPath === undefined) delete process.env.PATH;
  else process.env.PATH = originalPath;
  if (originalLogPath === undefined) delete process.env.CMUX_PI_INITIALIZATION_TEST_LOG;
  else process.env.CMUX_PI_INITIALIZATION_TEST_LOG = originalLogPath;
  await rm(fixtureRoot, { recursive: true, force: true });
}

console.log("Pi initialization serialization assertions passed");

export {};
