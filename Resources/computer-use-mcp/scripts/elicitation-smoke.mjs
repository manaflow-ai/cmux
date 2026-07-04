#!/usr/bin/env node
// Hermetic protocol and safety smoke for cmux-computer-use-mcp.mjs.
//
// Uses the server's built-in fake provider via CMUX_CU_FAKE_PROVIDER=1, so it
// does not touch a real GUI, permissions database, or desktop state.

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { ElicitRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import process from "node:process";

const here = dirname(fileURLToPath(import.meta.url));
const serverPath = join(here, "..", "cmux-computer-use-mcp.mjs");
const REQUIRED_TOOLS = [
  "computer_target",
  "computer_apps",
  "computer_open",
  "computer_state",
  "computer_screenshot",
  "computer_click",
  "computer_type",
  "computer_key",
  "computer_scroll",
  "computer_drag",
  "computer_action",
  "computer_windows",
];

function fakeEnv(extraEnv = {}) {
  const env = { ...process.env, CMUX_CU_FAKE_PROVIDER: "1" };
  delete env.CMUX_CU_AUTO_APPROVE;
  return { ...env, ...extraEnv };
}

function summarizeResult(res) {
  const text = (res.content ?? [])
    .filter((c) => c.type === "text")
    .map((c) => c.text)
    .join("\n");
  return { isError: !!res.isError, text };
}

async function runCalls({ withElicitation, calls, expectMessage = null, extraEnv = {} }) {
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [serverPath],
    env: fakeEnv(extraEnv),
    stderr: "pipe",
  });
  const client = new Client(
    { name: "cu-elicitation-smoke", version: "0.0.1" },
    withElicitation ? { capabilities: { elicitation: {} } } : undefined
  );
  if (withElicitation) {
    client.setRequestHandler(ElicitRequestSchema, async (request) => {
      const expectedMessages = Array.isArray(expectMessage)
        ? expectMessage
        : expectMessage
          ? [expectMessage]
          : [];
      for (const expected of expectedMessages) {
        if (!request.params.message.includes(expected)) {
          throw new Error(`unexpected elicitation message: ${request.params.message}`);
        }
      }
      return { action: "accept", content: {} };
    });
  }
  await client.connect(transport);
  const { tools } = await client.listTools();
  const missing = REQUIRED_TOOLS.filter((name) => !tools.some((tool) => tool.name === name));
  if (missing.length > 0) {
    await client.close();
    throw new Error(`missing required tools: ${missing.join(", ")}`);
  }
  const results = [];
  for (const call of calls) {
    const res = await client.callTool({ name: call.tool, arguments: call.args ?? {} });
    results.push(summarizeResult(res));
  }
  await client.close();
  return results;
}

async function run({ withElicitation, tool = "computer_state", args = { app: "TestApp" }, expectMessage = null, extraEnv = {} }) {
  const [result] = await runCalls({
    withElicitation,
    calls: [{ tool, args }],
    expectMessage,
    extraEnv,
  });
  return result;
}

async function runConcurrentElementRace() {
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [serverPath],
    env: fakeEnv({ CMUX_CU_AUTO_APPROVE: "1" }),
    stderr: "pipe",
  });
  const client = new Client({ name: "cu-elicitation-smoke", version: "0.0.1" });
  await client.connect(transport);
  const state = summarizeResult(
    await client.callTool({ name: "computer_state", arguments: { app: "TestApp" } })
  );
  const [first, second] = await Promise.all([
    client.callTool({ name: "computer_click", arguments: { app: "TestApp", element: 1 } }),
    client.callTool({ name: "computer_click", arguments: { app: "TestApp", element: 1 } }),
  ]);
  await client.close();
  return [state, summarizeResult(first), summarizeResult(second)];
}

async function runQueueBoundSmoke() {
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [serverPath],
    env: fakeEnv({ CMUX_CU_AUTO_APPROVE: "1" }),
    stderr: "pipe",
  });
  const client = new Client({ name: "cu-elicitation-smoke", version: "0.0.1" });
  await client.connect(transport);
  const calls = [
    client.callTool({ name: "computer_state", arguments: { app: "QueueHoldApp" } }),
    ...Array.from({ length: 10 }, () => client.callTool({ name: "computer_target", arguments: {} })),
  ];
  const results = await Promise.all(
    calls.map((call) =>
      call.then((result) => summarizeResult(result)).catch((error) => ({
        isError: true,
        text: String(error?.message ?? error),
      }))
    )
  );
  await client.close();
  return results;
}

async function runCoordinateBoundsSmoke() {
  const results = await runCalls({
    withElicitation: true,
    calls: [
      { tool: "computer_state", args: { app: "TestApp" } },
      { tool: "computer_click", args: { app: "TestApp", x: -1, y: 0 } },
    ],
    expectMessage: "Allow cmux computer use to inspect and control",
  });
  return { state: results[0], click: results[1] };
}

async function runRawCancellationSmoke({ queued }) {
  const child = spawn(process.execPath, [serverPath], {
    stdio: ["pipe", "pipe", "pipe"],
    env: fakeEnv({ CMUX_CU_AUTO_APPROVE: "1" }),
  });
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => process.stderr.write(chunk));
  const pending = new Map();
  const lines = createInterface({ input: child.stdout });
  const send = (message) => child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", ...message })}\n`);
  const request = (id, method, params, timeoutMs = 1000) =>
    new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        pending.delete(id);
        reject(new Error(`${method} timed out`));
      }, timeoutMs);
      pending.set(id, { resolve, reject, timer });
      send({ id, method, params });
    });
  const notify = (method, params) => send({ method, params });
  lines.on("line", (line) => {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      return;
    }
    const entry = pending.get(message.id);
    if (!entry) return;
    pending.delete(message.id);
    clearTimeout(entry.timer);
    entry.resolve(message);
  });
  child.on("exit", () => {
    for (const [id, entry] of pending) {
      pending.delete(id);
      clearTimeout(entry.timer);
      entry.reject(new Error("server exited"));
    }
  });
  try {
    await request("init", "initialize", { protocolVersion: "2025-06-18", capabilities: {} });
    if (!queued) {
      const slow = request(
        "slow-state",
        "tools/call",
        { name: "computer_state", arguments: { app: "SlowStateApp" } },
        1000
      )
        .then((message) => summarizeResult(message.result))
        .catch((error) => ({ isError: true, text: String(error?.message ?? error) }));
      setTimeout(() => notify("notifications/cancelled", { requestId: "slow-state", reason: "cancel smoke" }), 25);
      const afterCancel = await request(
        "after-cancel",
        "tools/call",
        { name: "computer_target", arguments: {} },
        1000
      )
        .then((message) => summarizeResult(message.result))
        .catch((error) => ({ isError: true, text: String(error?.message ?? error) }));
      return { result: await slow, afterCancel };
    }

    const rounds = [];
    for (let index = 0; index < 7; index += 1) {
      const activeId = `active-state-${index}`;
      const queuedId = `queued-target-${index}`;
      const active = request(
        activeId,
        "tools/call",
        { name: "computer_state", arguments: { app: "QueueHoldApp" } },
        1000
      )
        .then((message) => summarizeResult(message.result))
        .catch((error) => ({ isError: true, text: String(error?.message ?? error) }));
      const queuedCall = request(
        queuedId,
        "tools/call",
        { name: "computer_target", arguments: {} },
        1000
      )
        .then((message) => summarizeResult(message.result))
        .catch((error) => ({ isError: true, text: String(error?.message ?? error) }));
      setTimeout(() => notify("notifications/cancelled", { requestId: queuedId, reason: "cancel smoke" }), 25);
      rounds.push({ active: await active, queued: await queuedCall });
    }
    const postActive = request(
      "post-active-state",
      "tools/call",
      { name: "computer_state", arguments: { app: "QueueHoldApp" } },
      1000
    )
      .then((message) => summarizeResult(message.result))
      .catch((error) => ({ isError: true, text: String(error?.message ?? error) }));
    const followUp = request(
      "post-queued-target",
      "tools/call",
      { name: "computer_target", arguments: {} },
      1000
    )
      .then((message) => summarizeResult(message.result))
      .catch((error) => ({ isError: true, text: String(error?.message ?? error) }));
    return { rounds, postActive: await postActive, followUp: await followUp };
  } finally {
    child.kill();
  }
}

async function runUnknownCancellationSmoke() {
  const child = spawn(process.execPath, [serverPath], {
    stdio: ["pipe", "pipe", "pipe"],
    env: fakeEnv(),
  });
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => process.stderr.write(chunk));
  const pending = new Map();
  const lines = createInterface({ input: child.stdout });
  const send = (message) => child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", ...message })}\n`);
  const request = (id, method, params, timeoutMs = 1000) =>
    new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        pending.delete(id);
        reject(new Error(`${method} timed out`));
      }, timeoutMs);
      pending.set(id, { resolve, reject, timer });
      send({ id, method, params });
    });
  const notify = (method, params) => send({ method, params });
  lines.on("line", (line) => {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      return;
    }
    const entry = pending.get(message.id);
    if (!entry) return;
    pending.delete(message.id);
    clearTimeout(entry.timer);
    entry.resolve(message);
  });
  child.on("exit", () => {
    for (const [id, entry] of pending) {
      pending.delete(id);
      clearTimeout(entry.timer);
      entry.reject(new Error("server exited"));
    }
  });
  try {
    await request("init", "initialize", { protocolVersion: "2025-06-18", capabilities: {} });

    notify("notifications/cancelled", { requestId: "unknown-cancel", reason: "unknown smoke" });
    const afterUnknown = await request(
      "unknown-cancel",
      "tools/call",
      { name: "computer_target", arguments: {} },
      1000
    )
      .then((message) => summarizeResult(message.result))
      .catch((error) => ({ isError: true, text: String(error?.message ?? error) }));

    const completed = await request(
      "late-cancel",
      "tools/call",
      { name: "computer_target", arguments: {} },
      1000
    )
      .then((message) => summarizeResult(message.result))
      .catch((error) => ({ isError: true, text: String(error?.message ?? error) }));
    notify("notifications/cancelled", { requestId: "late-cancel", reason: "late smoke" });
    const afterLate = await request(
      "late-cancel",
      "tools/call",
      { name: "computer_target", arguments: {} },
      1000
    )
      .then((message) => summarizeResult(message.result))
      .catch((error) => ({ isError: true, text: String(error?.message ?? error) }));

    return { afterUnknown, completed, afterLate };
  } finally {
    child.kill();
  }
}

const accepted = await run({
  withElicitation: true,
  expectMessage: ["Allow cmux computer use to inspect and control", "cu-elicitation-smoke", "screenshots", "accessibility tree"],
});
console.log(`with elicitation support -> isError=${accepted.isError} text=${accepted.text}`);
if (accepted.isError || !accepted.text.includes("AXButton")) {
  console.error("FAIL: app-control elicitation was not forwarded to the client and accepted");
  process.exit(1);
}

const declined = await run({ withElicitation: false });
console.log(`without elicitation support -> isError=${declined.isError} text=${declined.text}`);
if (!declined.isError || !declined.text.includes("not approved")) {
  console.error("FAIL: expected fail-closed decline for a client without elicitation support");
  process.exit(1);
}

const [raceState, raceFirst, raceSecond] = await runConcurrentElementRace();
console.log(`concurrent element race -> state=${raceState.isError} first=${raceFirst.isError} second=${raceSecond.isError}`);
if (raceState.isError || raceFirst.isError || !raceSecond.isError || !raceSecond.text.includes("computer_state")) {
  console.error("FAIL: queued element action should consume the snapshot before the second action");
  process.exit(1);
}

const coordinateBounds = await runCoordinateBoundsSmoke();
console.log(
  `coordinate bounds -> state=${coordinateBounds.state.isError} click=${coordinateBounds.click.isError} text=${coordinateBounds.click.text}`
);
if (
  coordinateBounds.state.isError ||
  !coordinateBounds.click.isError ||
  !coordinateBounds.click.text.includes("coordinates")
) {
  console.error("FAIL: coordinate actions outside the latest screenshot should be rejected");
  process.exit(1);
}

const cancelled = await runRawCancellationSmoke({ queued: false });
console.log(
  `cancelled tool call -> isError=${cancelled.result.isError} followUp=${cancelled.afterCancel.isError} text=${cancelled.afterCancel.text}`
);
if (!cancelled.result.isError) {
  console.error("FAIL: cancelled tool call should not complete successfully");
  process.exit(1);
}
if (cancelled.afterCancel.isError) {
  console.error("FAIL: cancellation should release the tool queue for the next call");
  process.exit(1);
}

const queuedCancelled = await runRawCancellationSmoke({ queued: true });
const queuedCancellationFailed = queuedCancelled.rounds.some((round) => round.active.isError || !round.queued.isError);
console.log(
  `queued cancellation -> failed=${queuedCancellationFailed} postActive=${queuedCancelled.postActive.isError} followUp=${queuedCancelled.followUp.isError}`
);
if (queuedCancellationFailed || queuedCancelled.postActive.isError || queuedCancelled.followUp.isError) {
  console.error("FAIL: queued cancellations should clean up their tokens without stopping active or later calls");
  process.exit(1);
}

const unknownCancelled = await runUnknownCancellationSmoke();
console.log(
  `unknown cancellation -> afterUnknown=${unknownCancelled.afterUnknown.isError} completed=${unknownCancelled.completed.isError} afterLate=${unknownCancelled.afterLate.isError}`
);
if (unknownCancelled.afterUnknown.isError || unknownCancelled.completed.isError || unknownCancelled.afterLate.isError) {
  console.error("FAIL: unknown or late cancellations should not poison reusable request ids");
  process.exit(1);
}

const queueBounded = await runQueueBoundSmoke();
const queueRejected = queueBounded.filter((result) => result.isError && result.text.includes("too many")).length;
console.log(`queue bound -> first=${queueBounded[0].isError} rejected=${queueRejected}`);
if (queueBounded[0].isError || queueRejected === 0) {
  console.error("FAIL: concurrent tool calls should be bounded with a clear error");
  process.exit(1);
}

const largeArgs = await run({
  withElicitation: false,
  tool: "computer_type",
  args: { app: "TestApp", text: "x".repeat(300000) },
});
console.log(`large arguments -> isError=${largeArgs.isError}`);
if (!largeArgs.isError || !largeArgs.text.includes("too large")) {
  console.error("FAIL: oversized tool-call arguments should be rejected before queueing");
  process.exit(1);
}

const appsDeclined = await run({ withElicitation: false, tool: "computer_apps", args: {} });
console.log(`computer_apps without elicitation support -> isError=${appsDeclined.isError}`);
if (!appsDeclined.isError || !appsDeclined.text.includes("not approved")) {
  console.error("FAIL: expected fail-closed decline for app inventory");
  process.exit(1);
}

const appsAccepted = await run({
  withElicitation: true,
  tool: "computer_apps",
  args: {},
  expectMessage: "running controllable apps",
});
console.log(`computer_apps with accepted elicitation -> isError=${appsAccepted.isError}`);
if (appsAccepted.isError || !appsAccepted.text.includes("TestApp")) {
  console.error("FAIL: accepted elicitation should clear the app-inventory gate");
  process.exit(1);
}

const windowsDeclined = await run({ withElicitation: false, tool: "computer_windows", args: {} });
console.log(`computer_windows without elicitation support -> isError=${windowsDeclined.isError}`);
if (!windowsDeclined.isError || !windowsDeclined.text.includes("not approved")) {
  console.error("FAIL: expected fail-closed decline for local window enumeration");
  process.exit(1);
}

const shotDeclined = await run({ withElicitation: false, tool: "computer_screenshot", args: {} });
console.log(`desktop screenshot without elicitation support -> isError=${shotDeclined.isError}`);
if (!shotDeclined.isError || !shotDeclined.text.includes("not approved")) {
  console.error("FAIL: expected fail-closed decline for desktop capture");
  process.exit(1);
}

const windowsAccepted = await run({ withElicitation: true, tool: "computer_windows", args: {} });
console.log(`computer_windows with accepted elicitation -> isError=${windowsAccepted.isError}`);
if (windowsAccepted.isError || windowsAccepted.text.includes("not approved")) {
  console.error("FAIL: accepted elicitation should clear the window-list gate");
  process.exit(1);
}

const windowsAcceptedJa = await run({
  withElicitation: true,
  tool: "computer_windows",
  args: {},
  expectMessage: "ウィンドウ",
  extraEnv: { LC_ALL: "ja_JP.UTF-8" },
});
console.log(`computer_windows with Japanese approval prompt -> isError=${windowsAcceptedJa.isError}`);
if (windowsAcceptedJa.text.includes("not approved")) {
  console.error("FAIL: localized accepted elicitation should clear the window-list gate");
  process.exit(1);
}

const shotAccepted = await run({
  withElicitation: true,
  tool: "computer_screenshot",
  args: { display: -999 },
});
console.log(`desktop screenshot with accepted elicitation -> isError=${shotAccepted.isError}`);
if (shotAccepted.text.includes("not approved")) {
  console.error("FAIL: accepted elicitation should clear the desktop-capture gate");
  process.exit(1);
}

const openDeclined = await run({ withElicitation: false, tool: "computer_open", args: { app: "TestApp" } });
console.log(`computer_open without elicitation support -> isError=${openDeclined.isError}`);
if (!openDeclined.isError || !openDeclined.text.includes("not approved")) {
  console.error("FAIL: expected fail-closed decline for app launch");
  process.exit(1);
}

const openAccepted = await run({
  withElicitation: true,
  tool: "computer_open",
  args: { app: "TestApp" },
});
console.log(`computer_open with accepted elicitation -> isError=${openAccepted.isError}`);
if (openAccepted.isError || openAccepted.text.includes("not approved")) {
  console.error("FAIL: accepted elicitation should clear app launch");
  process.exit(1);
}
