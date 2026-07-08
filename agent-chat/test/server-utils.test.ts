import {
  assetCacheStatsForTest,
  buildBundles,
  cssAsset,
  cssFontFamily,
  gitOutputWithCodes,
  resetAssetCachesForTest,
  resolveFileDiffPath,
} from "../server";
import { mkdir, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";

function assert(cond: unknown, msg: string): asserts cond {
  if (!cond) throw new Error(msg);
}

delete process.env.CMUX_AGENT_UI_DEV;
resetAssetCachesForTest();
const [firstBundles, secondBundles] = await Promise.all([buildBundles(), buildBundles()]);
assert(firstBundles === secondBundles, "buildBundles should return the cached bundle map by default");
assert(assetCacheStatsForTest().bundleBuildCount === 1, "buildBundles should build once by default");

const firstCss = await cssAsset();
const secondCss = await cssAsset();
assert(firstCss === secondCss, "cssAsset should return the cached stylesheet by default");
assert(assetCacheStatsForTest().cssReadCount === 1, "cssAsset should read once by default");

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
const capped = await gitOutputWithCodes(root, ["diff", "--no-ext-diff", "HEAD", "--", "big.txt"], 4096, [0]);
assert(capped.includes("[truncated]"), "large git output should be marked truncated");
assert(new TextEncoder().encode(capped).byteLength < 4600, `large git output should stay near the cap, got ${capped.length} chars`);

console.log("server utility assertions passed");
