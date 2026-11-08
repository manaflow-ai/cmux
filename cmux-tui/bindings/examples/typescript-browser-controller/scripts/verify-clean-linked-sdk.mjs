import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  cpSync,
  existsSync,
  mkdtempSync,
  mkdirSync,
  rmSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const project = resolve(here, "..");
const sdk = resolve(project, "../..", "typescript");
const scratch = mkdtempSync(join(tmpdir(), "cmux-ts-clean-link-"));
const scratchBindings = join(scratch, "bindings");
const scratchSdk = join(scratchBindings, "typescript");
const scratchProject = join(
  scratchBindings,
  "examples",
  "typescript-browser-controller",
);

function includeSource(path) {
  return !["dist", "node_modules"].includes(basename(path));
}

try {
  mkdirSync(dirname(scratchProject), { recursive: true });
  cpSync(sdk, scratchSdk, { recursive: true, filter: includeSource });
  cpSync(project, scratchProject, { recursive: true, filter: includeSource });

  assert.equal(existsSync(join(scratchSdk, "dist")), false);
  assert.equal(existsSync(join(scratchProject, "node_modules")), false);

  execFileSync("npm", ["ci", "--no-audit", "--no-fund"], {
    cwd: scratchSdk,
    stdio: "pipe",
  });
  execFileSync("npm", ["run", "build"], {
    cwd: scratchSdk,
    stdio: "pipe",
  });
  execFileSync("npm", ["ci", "--no-audit", "--no-fund"], {
    cwd: scratchProject,
    stdio: "pipe",
  });
  execFileSync("npm", ["run", "build"], {
    cwd: scratchProject,
    stdio: "pipe",
  });
  const runtimeType = execFileSync(process.execPath, [
    "--input-type=module",
    "--eval",
    "import('cmux-sdk/browser').then(({ Client }) => process.stdout.write(typeof Client))",
  ], {
    cwd: scratchProject,
    encoding: "utf8",
  });
  assert.equal(runtimeType, "function");
  console.log("clean linked SDK consumer compile passed");
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
