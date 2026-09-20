import { deepStrictEqual, strictEqual } from "node:assert";
import { initializeAgentPath } from "../path-environment";

// Preserve the first search entry, spelling of Path, and even an absent PATH.
for (const inherited of [
  { PATH: "C:\\Python314\\Scripts\\;C:\\Windows\\System32", USERPROFILE: "C:\\Users\\test" },
  { Path: "C:\\Tools;C:\\Windows\\System32" },
  { PATH: "" },
  {},
]) {
  const env = { ...inherited };
  initializeAgentPath(env, "win32");
  deepStrictEqual(env, inherited);
}

for (const platform of ["darwin", "linux"] as const) {
  const env = { HOME: "/home/test", PATH: "/usr/bin:/usr/local/bin:/bin", KEEP: "value" };
  initializeAgentPath(env, platform);
  strictEqual(env.PATH, "/home/test/.local/bin:/home/test/.bun/bin:/opt/homebrew/bin:/usr/bin:/usr/local/bin:/bin");
  strictEqual(env.KEEP, "value");
  const once = { ...env };
  initializeAgentPath(env, platform);
  deepStrictEqual(env, once);
}
console.log("PATH environment assertions passed");

for (const platform of ["darwin", "linux"] as const) {
  for (const inherited of [{ HOME: "/home/test" }, { HOME: "/home/test", PATH: "" }]) {
    const env: Record<string, string> = { ...inherited };
    initializeAgentPath(env, platform);
    strictEqual(env.PATH, "/home/test/.local/bin:/home/test/.bun/bin:/opt/homebrew/bin:/usr/local/bin");
  }
}
