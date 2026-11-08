import { execFileSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const sdk = resolve(here, "../../..", "typescript");

execFileSync("npm", ["ci", "--no-audit", "--no-fund"], {
  cwd: sdk,
  stdio: "inherit",
});
execFileSync("npm", ["run", "build"], {
  cwd: sdk,
  stdio: "inherit",
});
