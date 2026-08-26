import { existsSync } from "node:fs";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

const root = await mkdtemp(join(tmpdir(), "cmux-agent-chat-shutdown-"));
const statePath = join(root, "state.json");
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
  for (let attempt = 0; attempt < 150; attempt++) {
    if (existsSync(statePath)) break;
    if (proc.exitCode !== null) break;
    await Bun.sleep(100);
  }
  assert(existsSync(statePath), "sidecar did not publish a state file");
  const state = JSON.parse(await readFile(statePath, "utf8"));
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
