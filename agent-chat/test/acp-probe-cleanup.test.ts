import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { makeAcpAdapter } from "../adapters/acp";

const directory = mkdtempSync(join(import.meta.dir, ".acp-probes-"));
const adapter = makeAcpAdapter({
  id: "fixture-acp-probes", label: "Fixture ACP", adapter: "acp",
  cmd: [process.execPath, join(import.meta.dir, "fake-acp-startup.ts"), directory],
});

function processes(): { pid: number; mode: string }[] {
  const journal = join(directory, "processes.jsonl");
  return existsSync(journal) ? readFileSync(journal, "utf8").trim().split("\n").filter(Boolean).map((line) => JSON.parse(line)) : [];
}

function alive(pid: number): boolean {
  try { process.kill(pid, 0); return true; }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ESRCH") return false;
    throw error;
  }
}

try {
  assert.ok(adapter.listOptions);
  assert.ok(adapter.listCommands);
  const modes = ["reject-initialize", "reject-session", "hang-initialize", "hang-session", "accept"];
  for (const [index, mode] of modes.entries()) {
    writeFileSync(join(directory, "mode"), mode);
    const results = await Promise.allSettled([adapter.listOptions(directory), adapter.listCommands(directory)]);
    if (mode.startsWith("reject")) {
      for (const result of results) {
        assert.equal(result.status, "rejected");
        if (result.status === "rejected") assert.match(String(result.reason), new RegExp(`fixture ${mode.slice(7)} rejected`));
      }
    } else {
      assert.equal(results[0]!.status, "fulfilled");
      assert.equal(results[1]!.status, "fulfilled");
      if (results[0]!.status === "fulfilled") {
        assert.ok(results[0]!.value.some((option) => option.id === "autoApprove"));
      }
      if (results[1]!.status === "fulfilled") {
        assert.deepEqual(results[1]!.value[0]!.commands.map((command) => command.name), mode === "accept" ? ["fixture"] : []);
      }
    }
    assert.equal(processes().length, (index + 1) * 2, "both catalog entrypoints must launch a disposable probe");
    assert.ok(processes().every((child) => !alive(child.pid)), "ACP catalog probes must be reaped before returning");
  }
  console.log("ACP option/command probes reap rejected, timed-out and successful children: OK");
} finally {
  const children = processes();
  for (const child of children) if (alive(child.pid)) process.kill(child.pid, "SIGKILL");
  const deadline = Date.now() + 2_000;
  while (children.some((child) => alive(child.pid)) && Date.now() < deadline) await Bun.sleep(10);
  rmSync(directory, { recursive: true, force: true });
  assert.ok(children.every((child) => !alive(child.pid)), "the fixture must leave no child processes behind");
}
