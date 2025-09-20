#!/usr/bin/env node
import { spawn, spawnSync } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import semver from "semver";

const __dirname = dirname(fileURLToPath(import.meta.url));
const projectRoot = resolve(__dirname, "..");
const packageJsonPath = resolve(projectRoot, "package.json");

const packageJsonRaw = readFileSync(packageJsonPath, "utf8");
const packageJson = JSON.parse(packageJsonRaw);

const versionRange =
  packageJson.devDependencies?.electron ??
  packageJson.dependencies?.electron ??
  packageJson.optionalDependencies?.electron;

if (!versionRange) {
  console.error("electron dependency is not declared in package.json");
  process.exit(1);
}

const version =
  semver.valid(versionRange) ?? semver.coerce(versionRange)?.version ?? undefined;

if (!version) {
  console.error(`Unable to determine Electron version from range: ${versionRange}`);
  process.exit(1);
}

// On macOS, if the Xcode license hasn't been accepted, invoking clang/cc will
// print a license notice instead of a version string, which breaks node-gyp's
// gyp condition evaluation (seen in bufferutil's binding.gyp). In that case,
// we skip rebuilding entirely since our native deps (bufferutil/utf-8-validate)
// are N-API with prebuilds and do not require rebuild for Electron.
if (process.platform === "darwin") {
  try {
    const res = spawnSync("clang", ["-v"], { encoding: "utf8" });
    const out = `${res.stdout ?? ""}${res.stderr ?? ""}`;
    if (/You have not agreed to the Xcode license/i.test(out)) {
      console.warn(
        "Skipping electron-rebuild: Xcode license not accepted; N-API prebuilds suffice."
      );
      process.exit(0);
    }
  } catch {
    // If clang isn't available for some reason, also skip; prebuilds will be used.
    console.warn("Skipping electron-rebuild: clang not available; using prebuilds.");
    process.exit(0);
  }
}

// If only N-API modules (bufferutil/utf-8-validate) are present, skip rebuild.
const workspaceRoot = resolve(projectRoot, "..");
const moduleDirs = [
  resolve(projectRoot, "node_modules"),
  resolve(workspaceRoot, "node_modules"),
];
const nodeModulesDir = moduleDirs.find((p) => existsSync(p));

if (nodeModulesDir) {
  const napiOnly = new Set(["bufferutil", "utf-8-validate"]); // N-API with prebuilds
  const fs = await import("node:fs");
  let hasOtherNative = false;
  let napiPresent = [];

  const checkPkg = (name, dir) => {
    const bindingGyp = resolve(dir, "binding.gyp");
    if (existsSync(bindingGyp)) {
      if (napiOnly.has(name)) napiPresent.push(name);
      else hasOtherNative = true;
    }
  };

  for (const entry of fs.readdirSync(nodeModulesDir)) {
    if (entry.startsWith(".")) continue;
    const full = resolve(nodeModulesDir, entry);
    try {
      if (fs.statSync(full).isDirectory()) {
        if (entry.startsWith("@")) {
          for (const sub of fs.readdirSync(full)) {
            const subFull = resolve(full, sub);
            if (fs.statSync(subFull).isDirectory()) checkPkg(`${entry}/${sub}`, subFull);
          }
        } else {
          checkPkg(entry, full);
        }
      }
    } catch {}
  }

  if (napiPresent.length > 0 && !hasOtherNative) {
    console.log(
      `Skipping electron-rebuild: only N-API modules detected (${napiPresent.join(", ")}).`
    );
    process.exit(0);
  }
}

const bunxBinary = process.platform === "win32" ? "bunx.cmd" : "bunx";

const runRebuild = (useElectronClang) =>
  new Promise((resolve, reject) => {
    const args = ["@electron/rebuild", "-f", "-t", "prod,dev"];
    if (useElectronClang) args.push("--use-electron-clang");
    args.push("--version", version);

    const child = spawn(bunxBinary, args, {
      cwd: projectRoot,
      env: process.env,
      stdio: ["inherit", "pipe", "pipe"],
    });

    let stdout = "";
    let stderr = "";

    child.stdout?.on("data", (chunk) => {
      stdout += chunk.toString();
      process.stdout.write(chunk);
    });

    child.stderr?.on("data", (chunk) => {
      stderr += chunk.toString();
      process.stderr.write(chunk);
    });

    child.on("error", (error) => {
      reject({ error, stdout, stderr, code: 1 });
    });

    child.on("exit", (code, signal) => {
      if (signal) {
        reject({ code: 1, signal, stdout, stderr });
      } else if (code && code !== 0) {
        reject({ code, stdout, stderr });
      } else {
        resolve({ stdout, stderr });
      }
    });
  });

try {
  await runRebuild(false);
  process.exit(0);
} catch (error) {
  if (error?.stderr) {
    process.stderr.write(error.stderr);
  }
  if (error?.error) {
    console.error("Failed to launch electron-rebuild:", error.error);
  }
  process.exit(error?.code ?? 1);
}
