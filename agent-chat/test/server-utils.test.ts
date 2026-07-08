import {
  assetCacheStatsForTest,
  buildBundles,
  cssAsset,
  cssFontFamily,
  resetAssetCachesForTest,
  resolveFileDiffPath,
} from "../server";

function assert(cond: unknown, msg: string): asserts cond {
  if (!cond) throw new Error(msg);
}

delete process.env.CMUX_AGENT_UI_DEV;
resetAssetCachesForTest();
const firstBundles = await buildBundles();
const secondBundles = await buildBundles();
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
const sanitized = cssFontFamily(`Bad";} body { color:red, Good\\Name`, fallback);
assert(!/[;{}]/.test(sanitized), `sanitized font family should not contain CSS breakers: ${sanitized}`);
assert(sanitized.includes(`"Bad\\" body  color:red"`), `sanitized font family should escape quotes: ${sanitized}`);
assert(sanitized.includes(`"Good\\\\Name"`), `sanitized font family should escape backslashes: ${sanitized}`);

console.log("server utility assertions passed");
