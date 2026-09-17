import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const project = resolve(here, "..");
const sdk = resolve(project, "../..", "typescript");
const scratch = mkdtempSync(join(tmpdir(), "cmux-ts-consumer-"));

try {
  const packed = JSON.parse(execFileSync("npm", [
    "pack",
    sdk,
    "--json",
    "--pack-destination",
    scratch,
  ], { encoding: "utf8" }));
  const filename = packed[0]?.filename;
  assert.equal(typeof filename, "string");
  const archive = join(scratch, filename);
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
      strict: true,
      noEmit: true,
      skipLibCheck: true,
    },
    include: ["consumer.ts"],
  }));
  writeFileSync(join(consumer, "consumer.ts"), `
import {
  Client,
  WebSocketTransport,
  browserId,
  decimalString,
  paneId,
  screenId,
  selectCurrent,
  workspaceId,
  type CreatedBrowserPath,
  type MutationResult,
  type WebSocketConstructor,
} from "cmux-sdk/browser";

declare const InjectedWebSocket: WebSocketConstructor;
const transport = new WebSocketTransport("ws://127.0.0.1:7681", {
  WebSocket: InjectedWebSocket,
  authToken: "token",
});
const client = new Client({ transport });
const session = client.session(selectCurrent());
const pane = session
  .workspace(workspaceId("ws_11111111111111111111111111111111"))
  .screen(screenId("screen_22222222222222222222222222222222"))
  .pane(paneId("pane_33333333333333333333333333333333"));
const created: Promise<MutationResult<CreatedBrowserPath>> =
  pane.createBrowserTab(
  { url: "https://example.com" },
  {
    correlationKey: "packaged-browser",
    idempotencyKey: "packaged-browser-attempt-1",
  },
);
void created.then((result) => result.value.browser.id);
void session.creation.resolve("packaged-browser");
const browser = session
  .browser(browserId("browser_ffffffffffffffffffffffffffffffff"));
void browser.navigate("https://example.com");
const pointerFrameSeq = decimalString("42");
void browser.mouse({
  kind: "move",
  xPx: 10,
  yPx: 20,
  pointerFrameSeq,
});
void browser.wheel({
  deltaX: 0,
  deltaY: -120,
  xPx: 10,
  yPx: 20,
  pointerFrameSeq,
});
void browser.attach({ signal: new AbortController().signal }).then((stream) => (
  stream.cancel()
));
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
    stdio: "pipe",
  });

  const installed = JSON.parse(readFileSync(
    join(consumer, "node_modules/cmux-sdk/package.json"),
    "utf8",
  ));
  assert.equal(installed.name, "cmux-sdk");
  assert.deepEqual(installed.dependencies ?? {}, {});
  const runtimeType = execFileSync(process.execPath, [
    "--input-type=module",
    "--eval",
    "import('cmux-sdk/browser').then(({ Client }) => process.stdout.write(typeof Client))",
  ], { cwd: consumer, encoding: "utf8" });
  assert.equal(runtimeType, "function");
  console.log("packaged npm consumer compile passed");
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
