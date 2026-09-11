import { existsSync } from "node:fs";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

const root = await mkdtemp(join(tmpdir(), "cmux-agent-chat-shutdown-"));
const statePath = join(root, "state.json");
await writeFile(statePath, "", "utf8");
const serverPath = join(import.meta.dir, "..", "server.ts");
const proc = Bun.spawn(["bun", serverPath, "--port=0"], {
  cwd: join(import.meta.dir, ".."),
  stdout: "inherit",
  stderr: "inherit",
  env: {
    ...process.env,
    CMUX_AGENT_CHAT_STATE_FILE: statePath,
    CMUX_AGENT_CHAT_LAUNCH_ID: "launch-test",
  },
});

let exited = false;
try {
  let state: { pid?: number; launchId?: string } | undefined;
  for (let attempt = 0; attempt < 150; attempt++) {
    try {
      const contents = await readFile(statePath, "utf8");
      if (contents.trim()) {
        const candidate: unknown = JSON.parse(contents);
        if (candidate && typeof candidate === "object") {
          const record = candidate as Record<string, unknown>;
          if (
            typeof record.pid === "number" &&
            Number.isInteger(record.pid) &&
            record.pid > 0 &&
            record.launchId === "launch-test"
          ) {
            state = { pid: record.pid, launchId: record.launchId };
            break;
          }
        }
      }
    } catch {
      // The state file may not exist or may still be publishing.
    }
    if (proc.exitCode !== null) break;
    await Bun.sleep(100);
  }
  assert(state, `sidecar did not publish a parseable state file (exitCode=${proc.exitCode})`);
  assert(state.pid === proc.pid, "state file should identify the launched sidecar");
  assert(state.launchId === "launch-test", "state file should identify the launch generation");

  proc.kill("SIGTERM");
  const exitCode = await proc.exited;
  exited = true;
  assert(exitCode === 0, `SIGTERM shutdown exited with ${exitCode}`);
  assert(!existsSync(statePath), "SIGTERM shutdown should remove the owned state file");
} finally {
  if (!exited && proc.exitCode === null) proc.kill("SIGKILL");
  if (!exited) await proc.exited;
  await rm(root, { recursive: true, force: true });
}

console.log("agent-chat shutdown assertions passed");
