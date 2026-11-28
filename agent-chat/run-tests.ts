// Runs every test/*.test.ts. Files that import bun:test run together in one
// `bun test`; the rest are plain assertion scripts, each run in its own
// process because several install globals (document, location) and never
// restore them.
import { Glob } from "bun";

const suites: string[] = [];
const scripts: string[] = [];
for (const name of [...new Glob("*.test.ts").scanSync(`${import.meta.dir}/test`)].sort()) {
  const source = await Bun.file(`${import.meta.dir}/test/${name}`).text();
  (/from ["']bun:test["']/.test(source) ? suites : scripts).push(`./test/${name}`);
}

const failed: string[] = [];
async function run(label: string, args: string[]) {
  const code = await Bun.spawn([process.execPath, ...args], { cwd: import.meta.dir, stdio: ["inherit", "inherit", "inherit"] }).exited;
  if (code !== 0) failed.push(label);
}

for (const script of scripts) await run(script, [script]);
if (suites.length) await run("bun test", ["test", ...suites]);

console.log(`${scripts.length} scripts and ${suites.length} bun:test files ran`);
if (failed.length) {
  console.error(`failed: ${failed.join(", ")}`);
  process.exit(1);
}
