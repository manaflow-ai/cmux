import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  existsSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const project = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const scratch = mkdtempSync(join(tmpdir(), "cmux-typescript-package-"));

try {
  let archive;
  if (process.env.CMUX_NPM_PACKAGE) {
    archive = resolve(process.env.CMUX_NPM_PACKAGE);
    assert.ok(existsSync(archive), `package archive does not exist: ${archive}`);
  } else {
    const packed = JSON.parse(execFileSync("npm", [
      "pack",
      project,
      "--json",
      "--pack-destination",
      scratch,
    ], { encoding: "utf8" }));
    const filename = packed[0]?.filename;
    assert.equal(typeof filename, "string");
    archive = join(scratch, filename);
  }

  const consumer = join(scratch, "consumer");
  mkdirSync(consumer);
  writeFileSync(join(consumer, "package.json"), JSON.stringify({
    private: true,
    type: "module",
  }));
  writeFileSync(join(consumer, "tsconfig.json"), JSON.stringify({
    compilerOptions: {
      target: "ES2022",
      module: "NodeNext",
      moduleResolution: "NodeNext",
      lib: ["ES2022", "DOM"],
      types: [],
      strict: true,
      noEmit: true,
      skipLibCheck: true,
    },
    include: ["consumer.ts"],
  }));
  writeFileSync(join(consumer, "consumer.ts"), `
import {
  Client,
  browserId,
  decimalString,
  exact,
  paneId,
  screenId,
  selectCurrent,
  sessionId,
  terminalId,
  workspaceId,
  type CreatedBrowserPath,
  type CreatedPath,
  type CreatedTerminalPath,
  type CreationResolution,
  type Agent,
  type AgentReportOptions,
  type MutationResult,
  type MutationReceipt,
  type Terminal,
  type TerminalWaitExitResult,
  type Transport,
} from "cmux-sdk";
import { WebSocketTransport } from "cmux-sdk/browser";
import { NodeClient } from "cmux-sdk/node";
import { CmuxClient, COMMAND_METADATA } from "cmux-sdk/raw";

declare const transport: Transport;
const client = new Client({ transport, timeoutMs: 5_000 });
const session = client.session(sessionId("session_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
const selectedTerminalId = terminalId("term_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
const terminal = session.terminal(selectedTerminalId);
const pointerFrameSeq = decimalString("42");
const write: Promise<MutationReceipt> = terminal.write(
  "printf",
  { idempotencyKey: "consumer-write", expectedRevision: decimalString("7") },
);
const creation: Promise<CreationResolution> =
  session.creation.resolve("create-key");
const reportOptions: AgentReportOptions = {
  terminalId: selectedTerminalId,
  state: "working",
  source: "socket",
  sourceSession: "package-consumer",
};
const reported: Promise<MutationResult<Agent>> =
  session.reportAgent(reportOptions);
const workspace = session.workspace(
  workspaceId("ws_cccccccccccccccccccccccccccccccc"),
);
const launched: Promise<MutationResult<CreatedTerminalPath>> = workspace.run({
  command: exact(["printf", "%s", "$HOME"]),
});
const pane = workspace
  .screen(screenId("screen_dddddddddddddddddddddddddddddddd"))
  .pane(paneId("pane_eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"));
const createdBrowser: Promise<MutationResult<CreatedBrowserPath>> =
  pane.createBrowserTab({ url: "https://example.com" });
const browserHandle = session.browser(
  browserId("browser_ffffffffffffffffffffffffffffffff"),
);
void browserHandle.mouse({
  kind: "move",
  xPx: 10,
  yPx: 20,
  pointerFrameSeq,
});
void browserHandle.wheel({
  deltaX: 0,
  deltaY: -120,
  xPx: 10,
  yPx: 20,
  pointerFrameSeq,
});
function narrow(path: CreatedPath) {
  if (path.kind === "terminal") return path.terminal.id;
  if (path.kind === "browser") return path.browser.id;
  return path.workspace.id;
}
const exit: Promise<TerminalWaitExitResult> =
  terminal.waitExit(decimalString("1000"));
const current = selectCurrent();
const command = exact(["printf", "%s", "$HOME"]);
const browser = new WebSocketTransport("ws://127.0.0.1/cmux");
const node = new NodeClient({ session: "main" });
const raw = CmuxClient;
void COMMAND_METADATA;
void browser;
void client;
void command;
void creation;
void createdBrowser;
void current;
void exit;
void launched;
void narrow;
void node;
void raw;
void reportOptions;
void reported;
void session;
void terminal;
void write;
`);

  execFileSync("npm", [
    "install",
    "--ignore-scripts",
    "--no-audit",
    "--no-fund",
    "--no-package-lock",
    archive,
  ], { cwd: consumer, stdio: "pipe" });

  const compiler = resolve(project, "node_modules/typescript/bin/tsc");
  execFileSync(process.execPath, [compiler, "-p", join(consumer, "tsconfig.json")], {
    cwd: consumer,
    stdio: "inherit",
  });

  const installedRoot = join(consumer, "node_modules/cmux-sdk");
  const installed = JSON.parse(readFileSync(join(installedRoot, "package.json"), "utf8"));
  assert.equal(installed.name, "cmux-sdk");
  assert.deepEqual(installed.dependencies ?? {}, {});
  assert.deepEqual(Object.keys(installed.exports).sort(), [".", "./browser", "./node", "./raw"]);

  for (const entry of ["index.js", "browser.js"]) {
    const graph = dependencyGraph(join(installedRoot, "dist/src", entry));
    assert.ok(!graph.some((path) => path.includes("/raw/")));
    assert.ok(!graph.some((path) => path.includes("/generated/")));
    assert.ok(!graph.some((path) => path.endsWith("/node-transport.js")));
    assert.ok(!graph.some((path) => path.endsWith("/node.js")));
  }

  const rawBrowserGraph = dependencyGraph(
    join(installedRoot, "dist/src/raw/browser.js"),
  );
  assert.ok(!rawBrowserGraph.some((path) => path.endsWith("/node-transport.js")));
  assert.ok(!rawBrowserGraph.some((path) => path.endsWith("/node-client.js")));

  const runtimeTypes = execFileSync(process.execPath, [
    "--input-type=module",
    "--eval",
    `Promise.all([
      import("cmux-sdk"),
      import("cmux-sdk/browser"),
      import("cmux-sdk/node"),
      import("cmux-sdk/raw"),
    ]).then(([root, browser, node, raw]) => process.stdout.write([
      typeof root.Client,
      typeof browser.WebSocketTransport,
      typeof node.NodeClient,
      typeof raw.CmuxClient,
    ].join(",")))`,
  ], { cwd: consumer, encoding: "utf8" });
  assert.equal(runtimeTypes, "function,function,function,function");
  console.log("clean root/browser/node/raw npm consumer compile passed");
} finally {
  rmSync(scratch, { recursive: true, force: true });
}

function dependencyGraph(entry) {
  const pending = [entry];
  const visited = new Set();
  const importPattern = /(?:import|export)\s+(?:[^"'()]*?\sfrom\s*)?["']([^"']+)["']/g;
  while (pending.length > 0) {
    const file = pending.pop();
    if (visited.has(file)) continue;
    visited.add(file);
    const source = readFileSync(file, "utf8");
    for (const match of source.matchAll(importPattern)) {
      const specifier = match[1];
      assert.ok(!specifier.startsWith("node:"), `${file} imports ${specifier}`);
      if (!specifier.startsWith(".")) continue;
      const target = resolve(dirname(file), specifier);
      assert.ok(existsSync(target), `missing dependency ${target}`);
      pending.push(target);
    }
  }
  return [...visited];
}
