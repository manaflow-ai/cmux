import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { codexAdapter } from "../adapters/codex";

const directory = mkdtempSync(join(import.meta.dir, ".codex-initialize-"));
const originalSpawn = Bun.spawn;
const originalSetTimeout = globalThis.setTimeout;
// Select a real disposable child by absolute path. Do not depend on PATH
// lookup, which could resolve the installed Codex binary on a contributor Mac.
Bun.spawn = ((command: string[], options: Bun.SpawnOptions.SpawnOptions<"pipe", "pipe", "pipe">) => {
  assert.deepEqual(command, ["codex", "app-server"]);
  return originalSpawn([process.execPath, join(import.meta.dir, "fake-codex-initialize.ts")], {
    ...options,
    env: { ...options.env, CMUX_CODEX_INIT_TEST_DIRECTORY: directory },
  });
}) as typeof Bun.spawn;

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
  assert.ok(codexAdapter.listOptions);
  writeFileSync(join(directory, "mode"), "reject");
  for (let attempt = 1; attempt <= 2; attempt++) {
    // Concurrent callers must share the same failed startup, and a later retry
    // must get a new startup rather than a cached rejected promise.
    const results = await Promise.allSettled([codexAdapter.listOptions(directory), codexAdapter.listOptions(directory)]);
    for (const result of results) {
      assert.equal(result.status, "rejected");
      if (result.status === "rejected") assert.match(String(result.reason), /fixture initialization rejected/);
    }
    const children = processes();
    assert.equal(children.length, attempt, "concurrent initialization must remain single-flight");
    for (const child of children) {
      assert.equal(alive(child.pid), false, "failed initialization must reap its child before returning the error");
    }
  }

  writeFileSync(join(directory, "mode"), "hang");
  const timers: { run: () => void; delay: number; timer: ReturnType<typeof setTimeout> }[] = [];
  globalThis.setTimeout = ((callback: (...args: any[]) => void, delay: number, ...args: any[]) => {
    const timer = originalSetTimeout(callback, delay, ...args);
    timers.push({ run: () => callback(...args), delay, timer });
    return timer;
  }) as typeof setTimeout;
  const timedOut = assert.rejects(codexAdapter.listOptions(directory), /codex app-server did not initialize within 30s/);
  globalThis.setTimeout = originalSetTimeout;
  // Wait for the real child to consume initialize before firing the watchdog.
  // This exercises the same timeout/kill/reap path without spending 30 seconds
  // asleep or imposing a short wall-clock deadline on subprocess startup.
  const readyDeadline = Date.now() + 2_000;
  while (!existsSync(join(directory, "initialize-ready")) && Date.now() < readyDeadline) await Bun.sleep(10);
  assert.ok(existsSync(join(directory, "initialize-ready")), "fixture must consume initialize before timing out");
  assert.deepEqual(timers.map(({ delay }) => delay), [30_000, 30_000], "startup watchdog and initialize RPC retain their 30s deadlines");
  clearTimeout(timers[0]!.timer);
  timers[0]!.run();
  await timedOut;
  assert.equal(processes().length, 3);
  assert.ok(processes().every((child) => !alive(child.pid)), "timed-out initialization must reap its uncooperative child");

  writeFileSync(join(directory, "mode"), "accept");
  const options = await codexAdapter.listOptions(directory);
  assert.ok(options.find((option) => option.id === "model")?.choices?.some((choice) => choice.value === "fixture-model"));
  const children = processes();
  assert.equal(children.length, 4, "a later successful retry must create exactly one replacement server");
  assert.equal(children[3]!.mode, "accept");
  assert.equal(alive(children[3]!.pid), true, "successful initialization must keep its server running");
  await codexAdapter.listOptions(directory);
  assert.equal(processes().length, 4, "a successfully initialized server should be reused");
  console.log("Codex initialization rejection/timeout cleanup, single-flight and successful retry: OK");
} finally {
  const children = processes();
  // Only PIDs recorded by this disposable fixture are eligible for cleanup.
  for (const child of children) {
    if (alive(child.pid)) process.kill(child.pid, "SIGKILL");
  }
  const deadline = Date.now() + 2_000;
  while (children.some((child) => alive(child.pid)) && Date.now() < deadline) {
    await Bun.sleep(10);
  }
  Bun.spawn = originalSpawn;
  globalThis.setTimeout = originalSetTimeout;
  rmSync(directory, { recursive: true, force: true });
  assert.ok(children.every((child) => !alive(child.pid)), "the fixture must leave no child processes behind");
}
