import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { makeAcpAdapter } from "../adapters/acp";

const directory = mkdtempSync(join(import.meta.dir, ".acp-probes-"));
const originalSetTimeout = globalThis.setTimeout;
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
    rmSync(join(directory, "initialize-ready"), { force: true });
    rmSync(join(directory, "session-ready"), { force: true });
    let watchdogs: { callback: () => void; delay: number; timer: ReturnType<typeof setTimeout> }[] = [];
    if (mode.startsWith("hang")) {
      globalThis.setTimeout = ((callback: TimerHandler, delay?: number, ...args: any[]) => {
        const timer = originalSetTimeout(callback, delay, ...args) as unknown as ReturnType<typeof setTimeout>;
        if (delay === 8_000) watchdogs.push({ callback: callback as () => void, delay, timer });
        return timer;
      }) as typeof setTimeout;
    }
    const probes = Promise.allSettled([adapter.listOptions(directory), adapter.listCommands(directory)]);
    if (mode.startsWith("hang")) {
      const stage = mode.slice("hang-".length);
      const readyDeadline = Date.now() + 10_000;
      let probeChildren: { pid: number; mode: string }[] = [];
      try {
        while (Date.now() < readyDeadline) {
          probeChildren = processes().slice(-2);
          if (probeChildren.length === 2 && watchdogs.length === 2 && probeChildren.every((child) => existsSync(join(directory, `${stage}-ready-${child.pid}`)))) break;
          await Bun.sleep(10);
        }
        assert.equal(probeChildren.length, 2, `both ${stage} probes must journal before timing out`);
        assert.ok(probeChildren.every((child) => existsSync(join(directory, `${stage}-ready-${child.pid}`))), `both probes must consume ${stage} before timing out`);
        assert.equal(watchdogs.length, 2, "both catalog entrypoints must schedule an 8s watchdog");
        assert.ok(watchdogs.every((watchdog) => watchdog.delay === 8_000));
      } finally {
        globalThis.setTimeout = originalSetTimeout;
      }
      for (const watchdog of watchdogs) {
        clearTimeout(watchdog.timer);
        watchdog.callback();
      }
    }
    const results = await probes;
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
  globalThis.setTimeout = originalSetTimeout;
  const children = processes();
  for (const child of children) if (alive(child.pid)) process.kill(child.pid, "SIGKILL");
  const deadline = Date.now() + 2_000;
  while (children.some((child) => alive(child.pid)) && Date.now() < deadline) await Bun.sleep(10);
  rmSync(directory, { recursive: true, force: true });
  assert.ok(children.every((child) => !alive(child.pid)), "the fixture must leave no child processes behind");
}
