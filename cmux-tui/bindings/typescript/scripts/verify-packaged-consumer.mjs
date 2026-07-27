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
  const packed = JSON.parse(execFileSync("npm", [
    "pack",
    project,
    "--json",
    "--pack-destination",
    scratch,
  ], { encoding: "utf8" }));
  const filename = packed[0]?.filename;
  assert.equal(typeof filename, "string");

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
  CmuxAbortError,
  CmuxAuthorityError,
  CmuxClient,
  COMMAND_METADATA,
  type BrowserStreamEvent,
  type CmuxAuthority,
  type CmuxStream,
  type Transport,
} from "cmux/browser";

declare const transport: Transport;
const client = new CmuxClient({ transport, timeoutMs: 5_000 });
const provider = new CmuxClient({
  transport,
  authorities: ["frontend"],
  enableProviderAuthority: true,
});
const authorities: readonly CmuxAuthority[] = provider.authorities;
const pasteSince: 7 = COMMAND_METADATA.send.fields.paste.since;
const filtered = client.subscribe({ surface: 18446744073709551615n });
const lifetime = new AbortController();
const stream: Promise<CmuxStream<BrowserStreamEvent>> = client.attachBrowserSurface(
  18446744073709551615n,
  { signal: lifetime.signal, idleTimeoutMs: 30_000 },
);
void stream.then(async (events) => {
  const read = new AbortController();
  const event = await events.next({ signal: read.signal, timeoutMs: 1_000 });
  switch (event.event) {
    case "browser-state":
      console.log(event.url);
      break;
    case "unknown":
      console.log(event.wireEvent, event.raw);
      break;
  }
});
void CmuxAbortError;
void CmuxAuthorityError;
void authorities;
void filtered;
void pasteSince;
`);

  execFileSync("npm", [
    "install",
    "--ignore-scripts",
    "--no-audit",
    "--no-fund",
    "--no-package-lock",
    join(scratch, filename),
  ], { cwd: consumer, stdio: "pipe" });

  const compiler = resolve(project, "node_modules/typescript/bin/tsc");
  execFileSync(process.execPath, [compiler, "-p", join(consumer, "tsconfig.json")], {
    cwd: consumer,
    stdio: "pipe",
  });

  const installedRoot = join(consumer, "node_modules/cmux");
  const installed = JSON.parse(readFileSync(join(installedRoot, "package.json"), "utf8"));
  assert.equal(installed.name, "cmux");
  assert.deepEqual(installed.dependencies ?? {}, {});

  const browserEntry = join(installedRoot, "dist/src/browser.js");
  const visited = browserDependencyGraph(browserEntry);
  assert.ok(visited.some((path) => path.endsWith("/browser.js")));
  assert.ok(!visited.some((path) => path.endsWith("/node-client.js")));
  assert.ok(!visited.some((path) => path.endsWith("/node-transport.js")));

  const runtimeType = execFileSync(process.execPath, [
    "--input-type=module",
    "--eval",
    "import('cmux/browser').then(({ CmuxClient }) => process.stdout.write(typeof CmuxClient))",
  ], { cwd: consumer, encoding: "utf8" });
  assert.equal(runtimeType, "function");
  console.log("clean browser-only npm consumer compile passed");
} finally {
  rmSync(scratch, { recursive: true, force: true });
}

function browserDependencyGraph(entry) {
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
      assert.ok(existsSync(target), `missing browser dependency ${target}`);
      pending.push(target);
    }
  }
  return [...visited];
}
