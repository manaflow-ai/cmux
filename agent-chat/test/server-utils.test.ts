import {
  assetCacheStatsForTest,
  buildBundles,
  cssAsset,
  cssFontFamily,
  gitFilesFromOutput,
  gitOutputWithCodes,
  gitOutputWithCodesResult,
  insertDeferredTurnEvents,
  resetAssetCachesForTest,
  resolveFileDiffPath,
} from "../server";
import type { AgentEvent } from "../types";
import { mkdir, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";

function assert(cond: unknown, msg: string): asserts cond {
  if (!cond) throw new Error(msg);
}

const priorDev = process.env.CMUX_AGENT_UI_DEV;
try {
  delete process.env.CMUX_AGENT_UI_DEV;
  resetAssetCachesForTest();
  const [firstBundles, secondBundles] = await Promise.all([buildBundles(), buildBundles()]);
  assert(firstBundles === secondBundles, "buildBundles should return the cached bundle map by default");
  assert(assetCacheStatsForTest().bundleBuildCount === 1, "buildBundles should build once by default");

  const firstCss = await cssAsset();
  const secondCss = await cssAsset();
  assert(firstCss === secondCss, "cssAsset should return the cached stylesheet by default");
  assert(assetCacheStatsForTest().cssReadCount === 1, "cssAsset should read once by default");
} finally {
  if (priorDev === undefined) delete process.env.CMUX_AGENT_UI_DEV;
  else process.env.CMUX_AGENT_UI_DEV = priorDev;
}

const cwd = "/tmp/agent-chat-path-test";
assert(resolveFileDiffPath(cwd, "src/../file.ts") === "file.ts", "normal in-cwd paths should normalize");
for (const path of ["src/../../x", "../x", "..", "a\0b"]) {
  let rejected = false;
  try {
    resolveFileDiffPath(cwd, path);
  } catch {
    rejected = true;
  }
  assert(rejected, `expected path to be rejected: ${path}`);
}

const fallback = `"Cascadia Code", monospace`;
const sanitized = cssFontFamily(`Bad";} body { color:red</style>, Good\\Name`, fallback);
assert(!/[;{}<>]/.test(sanitized), `sanitized font family should not contain CSS/HTML breakers: ${sanitized}`);
assert(sanitized.includes(`"Bad\\" body  color:red/style"`), `sanitized font family should escape quotes and strip angle brackets: ${sanitized}`);
assert(sanitized.includes(`"Good\\\\Name"`), `sanitized font family should escape backslashes: ${sanitized}`);

const root = join(import.meta.dir, "..", "scratch", "git-output-cap-test");
await rm(root, { recursive: true, force: true });
await mkdir(root, { recursive: true });
async function run(cmd: string[], cwd = root) {
  const p = Bun.spawn(cmd, { cwd, stdout: "pipe", stderr: "pipe", env: { ...process.env } });
  const [err, code] = await Promise.all([new Response(p.stderr).text(), p.exited]);
  if (code !== 0) throw new Error(`${cmd.join(" ")} failed: ${err}`);
}
await run(["git", "init"]);
await writeFile(join(root, "big.txt"), "start\n");
await run(["git", "add", "big.txt"]);
await run(["git", "-c", "user.email=a@b.c", "-c", "user.name=agent", "commit", "-m", "init"]);
await writeFile(join(root, "big.txt"), Array.from({ length: 4000 }, (_, i) => `line ${i} ${"x".repeat(80)}`).join("\n") + "\n");
const cappedResult = await gitOutputWithCodesResult(root, ["diff", "--no-ext-diff", "HEAD", "--", "big.txt"], 4096, [0]);
assert(cappedResult.truncated, "large git output should carry truncation metadata");
assert(!cappedResult.text.includes("[truncated]"), "low-level git output should not append a display marker");
assert(new TextEncoder().encode(cappedResult.text).byteLength <= 4096, `large git output should stay within the cap, got ${cappedResult.text.length} chars`);
const capped = await gitOutputWithCodes(root, ["diff", "--no-ext-diff", "HEAD", "--", "big.txt"], 4096, [0]);
assert(!capped.includes("[truncated]"), "string git output should not append a display marker");
const files = gitFilesFromOutput({ text: "src/a.ts\nsrc/b.ts\npartial-or-marker", truncated: true });
assert(files.join("|") === "src/a.ts|src/b.ts", `truncated git files should drop torn final entries: ${files.join("|")}`);

const orderedEvents: AgentEvent[] = [
  { kind: "user", text: "first" },
  { kind: "assistant", text: "first answer" },
  { kind: "user", text: "second" },
  { kind: "assistant", text: "second answer" },
];
const generations = [1, 1, 2, 2];
const inserted = insertDeferredTurnEvents(orderedEvents, generations, 1, [
  { kind: "files-changed", files: [{ path: "a.txt", adds: 1, dels: 0, status: "modified" }] },
  { kind: "done", stats: "1s" },
]);
assert(inserted.insertedAt === 2 && !inserted.dropped, `deferred finalization inserted at wrong position: ${JSON.stringify(inserted)}`);
assert(orderedEvents.map((evt) => evt.kind).join("|") === "user|assistant|files-changed|done|user|assistant", "deferred finalization should precede the newer user event");
assert(generations.join("|") === "1|1|1|1|2|2", `deferred generations were not preserved: ${generations.join("|")}`);
const dropped = insertDeferredTurnEvents(orderedEvents, generations, 1, [{ kind: "done" }]);
assert(dropped.dropped, "duplicate finalization should be dropped once the turn already has a footer");

console.log("server utility assertions passed");
