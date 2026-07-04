#!/usr/bin/env node
// Verifies the per-app approval path: the codex app-server's
// `mcpServer/elicitation/request` must be forwarded to the MCP client as a
// real `elicitation/create` (approved by the human), and must fail closed
// (decline) for clients that never declared elicitation support.
//
// Uses scripts/fake-codex-app-server.mjs via CMUX_CU_CODEX, so it runs
// hermetically — no real codex install, auth, or GUI is touched.
//
//   node scripts/elicitation-smoke.mjs

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
const fakeCodex = join(here, "fake-codex-app-server.mjs");
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

function summarizeResult(res) {
  const text = (res.content ?? [])
    .filter((c) => c.type === "text")
    .map((c) => c.text)
    .join("\n");
  return { isError: !!res.isError, text };
}

async function runCalls({ withElicitation, calls, expectMessage = null, extraEnv = {} }) {
  // Hermetic env: pin the fake codex and strip any ambient auto-approve so a
  // developer shell with CMUX_CU_AUTO_APPROVE=1 cannot bypass the very
  // approval paths under test.
  const env = { ...process.env, CMUX_CU_CODEX: fakeCodex, ...extraEnv };
  delete env.CMUX_CU_AUTO_APPROVE;
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [serverPath],
    env,
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

async function run({ withElicitation, tool = "computer_apps", args = {}, expectMessage = null, extraEnv = {} }) {
  const [result] = await runCalls({
    withElicitation,
    calls: [{ tool, args }],
    expectMessage,
    extraEnv,
  });
  return result;
}

async function runRelativeCodexOverrideRejected() {
  const packageRoot = join(here, "..");
  const env = { ...process.env, CMUX_CU_CODEX: "./scripts/fake-codex-app-server.mjs" };
  delete env.CMUX_CU_AUTO_APPROVE;
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [serverPath],
    cwd: packageRoot,
    env,
    stderr: "pipe",
  });
  const client = new Client({ name: "cu-elicitation-smoke", version: "0.0.1" });
  await client.connect(transport);
  const result = summarizeResult(await client.callTool({ name: "computer_target", arguments: {} }));
  await client.close();
  return result;
}

async function runConcurrentElementRace() {
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [serverPath],
    env: { ...process.env, CMUX_CU_CODEX: fakeCodex },
    stderr: "pipe",
  });
  const client = new Client({ name: "cu-elicitation-smoke", version: "0.0.1" });
  await client.connect(transport);
  const state = summarizeResult(
    await client.callTool({ name: "computer_state", arguments: { app: "TestApp" } })
  );
  const [first, second] = await Promise.all([
    client.callTool({ name: "computer_click", arguments: { app: "TestApp", element: 0 } }),
    client.callTool({ name: "computer_click", arguments: { app: "TestApp", element: 0 } }),
  ]);
  await client.close();
  return [state, summarizeResult(first), summarizeResult(second)];
}

async function runCancellationSmoke() {
  const env = { ...process.env, CMUX_CU_CODEX: fakeCodex };
  delete env.CMUX_CU_AUTO_APPROVE;
  const child = spawn(process.execPath, [serverPath], { stdio: ["pipe", "pipe", "pipe"], env });
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
  } finally {
    child.kill();
  }
}

async function runQueuedCancellationSmoke() {
  const env = { ...process.env, CMUX_CU_CODEX: fakeCodex };
  delete env.CMUX_CU_AUTO_APPROVE;
  const child = spawn(process.execPath, [serverPath], { stdio: ["pipe", "pipe", "pipe"], env });
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
    const active = request(
      "active-state",
      "tools/call",
      { name: "computer_state", arguments: { app: "QueueHoldApp" } },
      1000
    )
      .then((message) => summarizeResult(message.result))
      .catch((error) => ({ isError: true, text: String(error?.message ?? error) }));
    const queued = request(
      "queued-target",
      "tools/call",
      { name: "computer_target", arguments: {} },
      1000
    )
      .then((message) => summarizeResult(message.result))
      .catch((error) => ({ isError: true, text: String(error?.message ?? error) }));
    setTimeout(() => notify("notifications/cancelled", { requestId: "queued-target", reason: "cancel smoke" }), 25);
    return { active: await active, queued: await queued };
  } finally {
    child.kill();
  }
}

const accepted = await run({
  withElicitation: true,
  expectMessage: ["Allow Codex to use TestApp?", "cu-elicitation-smoke", "screenshots", "accessibility tree"],
});
console.log(`with elicitation support -> isError=${accepted.isError} text=${accepted.text}`);
if (accepted.isError || !accepted.text.includes("elicitation:accept")) {
  console.error("FAIL: elicitation was not forwarded to the client and accepted");
  process.exit(1);
}

const relativeOverride = await runRelativeCodexOverrideRejected();
console.log(`relative CMUX_CU_CODEX override -> isError=${relativeOverride.isError}`);
if (!relativeOverride.isError || !relativeOverride.text.includes("absolute executable path")) {
  console.error("FAIL: relative CMUX_CU_CODEX should be rejected before spawning codex");
  process.exit(1);
}

const unknownRequest = await run({
  withElicitation: false,
  tool: "computer_state",
  args: { app: "UnknownRequestApp" },
});
console.log(`unknown app-server request -> isError=${unknownRequest.isError}`);
if (unknownRequest.isError || !unknownRequest.text.includes("unknown-request:rejected")) {
  console.error("FAIL: unknown app-server requests should fail closed with a JSON-RPC error");
  process.exit(1);
}

const cancelled = await runCancellationSmoke();
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

const queuedCancelled = await runQueuedCancellationSmoke();
console.log(
  `queued cancellation -> active=${queuedCancelled.active.isError} queued=${queuedCancelled.queued.isError}`
);
if (queuedCancelled.active.isError || !queuedCancelled.queued.isError) {
  console.error("FAIL: cancelling a queued tool call should not stop the active tool call");
  process.exit(1);
}

const declined = await run({ withElicitation: false });
console.log(`without elicitation support -> isError=${declined.isError} text=${declined.text}`);
if (!declined.isError || !declined.text.includes("elicitation:decline")) {
  console.error("FAIL: expected fail-closed decline for a client without elicitation support");
  process.exit(1);
}

// Local perception tools (window enumeration, desktop capture) bypass the
// codex engine, so they must sit behind the same approval boundary.
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
if (windowsAccepted.text.includes("not approved")) {
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
  // Use an invalid display so the smoke proves the approval gate opens without
  // requiring a real full-desktop capture or Screen Recording permission.
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

// Happy path through a local gate, hermetically: an accepted elicitation must
// clear the approval boundary and reach the underlying action. A nonexistent
// app makes `open -a` fail AFTER the gate, proving the gate passed without
// actually launching anything.
const openAccepted = await run({
  withElicitation: true,
  tool: "computer_open",
  args: { app: "cmux-cu-nonexistent-test-app" },
});
console.log(`computer_open with accepted elicitation -> isError=${openAccepted.isError}`);
if (!openAccepted.isError || openAccepted.text.includes("not approved")) {
  console.error("FAIL: accepted elicitation should clear the gate and reach `open -a`");
  process.exit(1);
}

const [openState, openAttempt, staleAfterOpen] = await runCalls({
  withElicitation: true,
  expectMessage: "launch or focus",
  calls: [
    { tool: "computer_state", args: { app: "OpenRevokesApp" } },
    { tool: "computer_open", args: { app: "OpenRevokesApp" } },
    { tool: "computer_click", args: { app: "OpenRevokesApp", element: 0 } },
  ],
});
console.log(
  `computer_open revokes snapshot -> state=${openState.isError} open=${openAttempt.isError} click=${staleAfterOpen.isError}`
);
if (
  openState.isError ||
  !openAttempt.isError ||
  !staleAfterOpen.isError ||
  !staleAfterOpen.text.includes("run computer_state first")
) {
  console.error("FAIL: computer_open should revoke old element indices before the next input");
  process.exit(1);
}

const [typeWithoutSnapshot] = await runCalls({
  withElicitation: false,
  calls: [{ tool: "computer_type", args: { app: "TypingApp", text: "hello" } }],
});
console.log(`type without visible snapshot -> type=${typeWithoutSnapshot.isError}`);
if (!typeWithoutSnapshot.isError || !typeWithoutSnapshot.text.includes("visible snapshot")) {
  console.error("FAIL: typing should require a visible state/screenshot snapshot");
  process.exit(1);
}

const [typingState, firstType, staleType] = await runCalls({
  withElicitation: false,
  calls: [
    { tool: "computer_state", args: { app: "TypingApp" } },
    { tool: "computer_type", args: { app: "TypingApp", text: "hello" } },
    { tool: "computer_type", args: { app: "TypingApp", text: "again" } },
  ],
});
console.log(`type from visible snapshot -> state=${typingState.isError} type=${firstType.isError} stale=${staleType.isError}`);
if (typingState.isError || firstType.isError || !staleType.isError || !staleType.text.includes("visible snapshot")) {
  console.error("FAIL: typing should consume the visible snapshot before another input");
  process.exit(1);
}

const [keyScreenshot, firstKey, staleKey] = await runCalls({
  withElicitation: false,
  calls: [
    { tool: "computer_screenshot", args: { app: "KeyApp" } },
    { tool: "computer_key", args: { app: "KeyApp", key: "Return" } },
    { tool: "computer_key", args: { app: "KeyApp", key: "Return" } },
  ],
});
console.log(`key from screenshot -> screenshot=${keyScreenshot.isError} key=${firstKey.isError} stale=${staleKey.isError}`);
if (keyScreenshot.isError || firstKey.isError || !staleKey.isError || !staleKey.text.includes("visible snapshot")) {
  console.error("FAIL: key input should consume the visible screenshot snapshot");
  process.exit(1);
}

const [stateResult, firstClick, staleClick] = await runCalls({
  withElicitation: false,
  calls: [
    { tool: "computer_state", args: { app: "TestApp" } },
    { tool: "computer_click", args: { app: "TestApp", element: 0 } },
    { tool: "computer_click", args: { app: "TestApp", element: 0 } },
  ],
});
console.log(
  `stale element sequence -> state=${stateResult.isError} firstClick=${firstClick.isError} staleClick=${staleClick.isError}`
);
if (stateResult.isError || firstClick.isError) {
  console.error("FAIL: expected first element action to use the fresh computer_state snapshot");
  process.exit(1);
}
if (!staleClick.isError || !staleClick.text.includes("run computer_state first")) {
  console.error("FAIL: stale element action should require a fresh computer_state snapshot");
  process.exit(1);
}

const [coordinateWithoutSnapshot] = await runCalls({
  withElicitation: false,
  calls: [{ tool: "computer_click", args: { app: "CoordinateApp", x: 3, y: 4 } }],
});
console.log(`coordinate click without visible snapshot -> click=${coordinateWithoutSnapshot.isError}`);
if (!coordinateWithoutSnapshot.isError || !coordinateWithoutSnapshot.text.includes("visible screenshot")) {
  console.error("FAIL: coordinate click should require a visible screenshot snapshot");
  process.exit(1);
}

const [coordinateState, coordinateClick, staleCoordinateClick] = await runCalls({
  withElicitation: false,
  calls: [
    { tool: "computer_state", args: { app: "CoordinateApp" } },
    { tool: "computer_click", args: { app: "CoordinateApp", x: 3, y: 4 } },
    { tool: "computer_click", args: { app: "CoordinateApp", x: 3, y: 4 } },
  ],
});
console.log(
  `coordinate click from computer_state -> state=${coordinateState.isError} click=${coordinateClick.isError} stale=${staleCoordinateClick.isError}`
);
if (
  coordinateState.isError ||
  coordinateClick.isError ||
  !staleCoordinateClick.isError ||
  !staleCoordinateClick.text.includes("visible screenshot")
) {
  console.error("FAIL: coordinate click should consume the visible computer_state snapshot");
  process.exit(1);
}

const [coordinateScreenshot, screenshotClick, staleScreenshotClick] = await runCalls({
  withElicitation: false,
  calls: [
    { tool: "computer_screenshot", args: { app: "ScreenshotCoordinateApp" } },
    { tool: "computer_click", args: { app: "ScreenshotCoordinateApp", x: 5, y: 6 } },
    { tool: "computer_click", args: { app: "ScreenshotCoordinateApp", x: 5, y: 6 } },
  ],
});
console.log(
  `coordinate click from computer_screenshot -> screenshot=${coordinateScreenshot.isError} click=${screenshotClick.isError} stale=${staleScreenshotClick.isError}`
);
if (
  coordinateScreenshot.isError ||
  screenshotClick.isError ||
  !staleScreenshotClick.isError ||
  !staleScreenshotClick.text.includes("visible screenshot")
) {
  console.error("FAIL: coordinate click should consume the visible computer_screenshot snapshot");
  process.exit(1);
}

const [dragState, dragResult, staleDrag] = await runCalls({
  withElicitation: false,
  calls: [
    { tool: "computer_state", args: { app: "DragCoordinateApp" } },
    {
      tool: "computer_drag",
      args: { app: "DragCoordinateApp", fromX: 1, fromY: 2, toX: 3, toY: 4 },
    },
    {
      tool: "computer_drag",
      args: { app: "DragCoordinateApp", fromX: 1, fromY: 2, toX: 3, toY: 4 },
    },
  ],
});
console.log(`coordinate drag -> state=${dragState.isError} drag=${dragResult.isError} stale=${staleDrag.isError}`);
if (dragState.isError || dragResult.isError || !staleDrag.isError || !staleDrag.text.includes("visible screenshot")) {
  console.error("FAIL: coordinate drag should consume the visible screenshot snapshot");
  process.exit(1);
}

const [flakyState, failedRefresh, staleAfterFailedRefresh] = await runCalls({
  withElicitation: false,
  calls: [
    { tool: "computer_state", args: { app: "FlakyStateApp" } },
    { tool: "computer_state", args: { app: "FlakyStateApp" } },
    { tool: "computer_click", args: { app: "FlakyStateApp", element: 0 } },
  ],
});
console.log(
  `failed state refresh revokes snapshot -> state=${flakyState.isError} refresh=${failedRefresh.isError} click=${staleAfterFailedRefresh.isError}`
);
if (
  flakyState.isError ||
  !failedRefresh.isError ||
  !staleAfterFailedRefresh.isError ||
  !staleAfterFailedRefresh.text.includes("run computer_state first")
) {
  console.error("FAIL: failed computer_state refresh should revoke old element indices");
  process.exit(1);
}

const [screenshotState, failedScreenshot, staleAfterFailedScreenshot] = await runCalls({
  withElicitation: false,
  calls: [
    { tool: "computer_state", args: { app: "FlakyScreenshotApp" } },
    { tool: "computer_screenshot", args: { app: "FlakyScreenshotApp" } },
    { tool: "computer_click", args: { app: "FlakyScreenshotApp", element: 0 } },
  ],
});
console.log(
  `failed screenshot refresh revokes snapshot -> state=${screenshotState.isError} screenshot=${failedScreenshot.isError} click=${staleAfterFailedScreenshot.isError}`
);
if (
  screenshotState.isError ||
  !failedScreenshot.isError ||
  !staleAfterFailedScreenshot.isError ||
  !staleAfterFailedScreenshot.text.includes("run computer_state first")
) {
  console.error("FAIL: failed computer_screenshot refresh should revoke old element indices");
  process.exit(1);
}

const [scrollState, scrollResult, actionState, actionResult] = await runCalls({
  withElicitation: false,
  calls: [
    { tool: "computer_state", args: { app: "TestApp" } },
    { tool: "computer_scroll", args: { app: "TestApp", element: 0, direction: "down" } },
    { tool: "computer_state", args: { app: "TestApp" } },
    { tool: "computer_action", args: { app: "TestApp", element: 0, action: "AXPress" } },
  ],
});
console.log(
  `element-index input tools -> scrollState=${scrollState.isError} scroll=${scrollResult.isError} actionState=${actionState.isError} action=${actionResult.isError}`
);
if (scrollState.isError || scrollResult.isError || actionState.isError || actionResult.isError) {
  console.error("FAIL: expected element-index input tools to forward numeric element_index values");
  process.exit(1);
}

const [raceState, raceA, raceB] = await runConcurrentElementRace();
const raceFailures = [raceA, raceB].filter((result) => result.isError);
console.log(
  `concurrent element race -> state=${raceState.isError} first=${raceA.isError} second=${raceB.isError}`
);
if (raceState.isError) {
  console.error("FAIL: expected race setup computer_state to succeed");
  process.exit(1);
}
if (raceFailures.length !== 1 || !raceFailures[0].text.includes("run computer_state first")) {
  console.error("FAIL: exactly one concurrent element action should consume the snapshot");
  process.exit(1);
}

console.log("PASS: elicitation forwarding + fail-closed/accepted gates (engine and local capabilities)");
