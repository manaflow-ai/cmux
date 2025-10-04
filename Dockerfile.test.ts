import { afterAll, expect, test } from "bun:test";
import { spawn } from "node:child_process";

type RunOptions = {
  cwd?: string;
  allowFailure?: boolean;
  env?: Record<string, string>;
};

type RunResult = {
  stdout: string;
  stderr: string;
  exitCode: number;
};

const repoRoot = process.cwd();
const LOCAL_TAG = "cmux-local-test";
const MORPH_TAG = "cmux-morph-test";

function runCommand(args: readonly string[], options: RunOptions = {}): Promise<RunResult> {
  return new Promise((resolve, reject) => {
    const [command, ...rest] = args;
    const child = spawn(command, rest, {
      cwd: options.cwd ?? repoRoot,
      env: { ...process.env, ...options.env },
      stdio: ["ignore", "pipe", "pipe"],
    });

    let stdout = "";
    let stderr = "";
    let settled = false;

    child.stdout?.setEncoding("utf8");
    child.stderr?.setEncoding("utf8");

    child.stdout?.on("data", (chunk) => {
      stdout += chunk;
    });

    child.stderr?.on("data", (chunk) => {
      stderr += chunk;
    });

    child.once("error", (err) => {
      if (settled) {
        return;
      }
      settled = true;
      if (options.allowFailure) {
        resolve({ stdout, stderr: `${stderr}${String(err)}`, exitCode: child.exitCode ?? 1 });
      } else {
        reject(err);
      }
    });

    child.on("close", (code) => {
      if (settled) {
        return;
      }
      settled = true;
      const exitCode = code ?? 0;
      if (exitCode !== 0 && !options.allowFailure) {
        const error = new Error(
          `Command failed: ${args.join(" ")}\nExit code: ${exitCode}\nStdout:\n${stdout}\nStderr:\n${stderr}`,
        );
        reject(error);
        return;
      }
      resolve({ stdout, stderr, exitCode });
    });
  });
}

await runCommand(["docker", "build", "-t", LOCAL_TAG, "."]);
await runCommand(["docker", "build", "--target", "morph", "-t", MORPH_TAG, "."]);

afterAll(async () => {
  await runCommand(["docker", "image", "rm", "-f", LOCAL_TAG], { allowFailure: true });
  await runCommand(["docker", "image", "rm", "-f", MORPH_TAG], { allowFailure: true });
});

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

async function waitForDocker(containerName: string, timeoutMs = 180_000, intervalMs = 2_000): Promise<void> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const infoResult = await runCommand(
      ["docker", "exec", containerName, "docker", "info"],
      { allowFailure: true },
    );
    if (infoResult.exitCode === 0) {
      return;
    }
    await sleep(intervalMs);
  }
  throw new Error(`Docker did not become ready inside container ${containerName}`);
}

test("local stage supports docker run hello-world", { timeout: 600_000 }, async () => {
  const containerName = `cmux-local-test-${Date.now()}`;
  await runCommand([
    "docker",
    "run",
    "-d",
    "--privileged",
    "--name",
    containerName,
    LOCAL_TAG,
  ]);

  try {
    await waitForDocker(containerName);
    const pullResult = await runCommand([
      "docker",
      "exec",
      containerName,
      "docker",
      "run",
      "--rm",
      "hello-world",
    ]);
    expect(pullResult.exitCode).toBe(0);
  } finally {
    await runCommand(["docker", "rm", "-f", containerName], { allowFailure: true });
  }
});

test("morph stage does not include docker", { timeout: 120_000 }, async () => {
  const script = "set -euo pipefail; if command -v docker >/dev/null 2>&1; then exit 1; fi";
  const result = await runCommand([
    "docker",
    "run",
    "--rm",
    "--entrypoint",
    "/bin/bash",
    MORPH_TAG,
    "-lc",
    script,
  ]);

  expect(result.exitCode).toBe(0);
});
