// Run the real adapter in a child with a fake codex executable on PATH. This
// exercises spawn, stdout EOF, resume and turn dispatch without user sessions.
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { codexAdapter, codexStopSharedServerForTest } from "../adapters/codex";
import type { AgentEvent, SessionCtx } from "../types";

async function waitUntil(check: () => boolean | Promise<boolean>) {
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    if (await check()) return;
    await Bun.sleep(10);
  }
  throw new Error("timed out waiting for fake Codex lifecycle");
}

if (!process.env.CMUX_TEST_CODEX_RECOVERY_DIR) {
  const root = await mkdtemp(join(tmpdir(), "cmux-codex-recovery-"));
  const quote = (value: string) => `'${value.replaceAll("'", "'\\''")}'`;
  await writeFile(join(root, "codex"), `#!/bin/sh\nexec ${quote(process.execPath)} ${quote(join(import.meta.dir, "fake-codex-recovery.ts"))}\n`);
  await chmod(join(root, "codex"), 0o700);
  const child = Bun.spawn([process.execPath, import.meta.path], {
    env: { ...process.env, PATH: `${root}:${process.env.PATH}`, CMUX_TEST_CODEX_RECOVERY_DIR: root },
    stdio: ["ignore", "inherit", "inherit"],
  });
  try {
    const result = await child.exited;
    if (result !== 0) throw new Error(`Codex recovery regression failed (${result})`);
  } finally {
    child.kill();
    const pids = (await readFile(join(root, "pids"), "utf8").catch(() => "")).trim().split(/\s+/).filter(Boolean);
    for (const pid of pids) { try { process.kill(Number(pid), "SIGKILL"); } catch {} }
    await rm(root, { recursive: true, force: true });
  }
} else {
  const root = process.env.CMUX_TEST_CODEX_RECOVERY_DIR;
  const requests = async () => (await readFile(join(root, "requests"), "utf8")).trim().split("\n").map((line) => JSON.parse(line));
  const latestPid = async () => Number((await readFile(join(root, "pids"), "utf8")).trim().split("\n").at(-1));
  function session(id: string): SessionCtx {
    return {
      id, provider: "codex", cwd: root, title: id, autoApprove: false,
      startOptions: {}, status: "idle", events: [], internal: {},
      emit(event: AgentEvent) { this.events.push(event); },
      setStatus(status) { this.status = status; },
    };
  }
  try {
    const idle = session("idle");
    const active = session("active");
    await codexAdapter.send(idle, "first prompt");
    await waitUntil(() => idle.events.some((event) => event.kind === "done"));
    await codexAdapter.send(active, "stay active");
    await waitUntil(() => active.status === "running");
    const idleThread = idle.internal.threadId;
    const activeThread = active.internal.threadId;
    process.kill(await latestPid(), "SIGKILL");
    await waitUntil(() => active.events.some((event) => event.kind === "error"));

    await codexAdapter.send(idle, "continue after crash");
    await codexAdapter.send(active, "continue after crash");
    await waitUntil(async () => (await requests()).filter((entry) => entry.method === "turn/start" && entry.params.input[0].text === "continue after crash").length === 2);
    const recorded = await requests();
    const starts = recorded.filter((entry) => entry.method === "thread/start");
    if (starts.length !== 2) {
      throw new Error(`crash recovery started ${starts.length} threads instead of preserving the original two`);
    }
    for (const threadId of [idleThread, activeThread]) {
      if (!recorded.some((entry) => entry.method === "thread/resume" && entry.params.threadId === threadId)) {
        throw new Error(`crash recovery did not resume ${threadId}`);
      }
      if (!recorded.some((entry) => entry.method === "turn/start" && entry.params.threadId === threadId && entry.params.input[0].text === "continue after crash")) {
        throw new Error(`recovered prompt was not delivered to ${threadId}`);
      }
    }

    // A failed resume must preserve the ID for retry, never fall back to a blank thread.
    await writeFile(join(root, "refuse-resume"), "1");
    const errorCount = idle.events.filter((event) => event.kind === "error").length;
    await codexAdapter.send(active, "stay active");
    process.kill(await latestPid(), "SIGKILL");
    const activeErrors = active.events.filter((event) => event.kind === "error").length;
    await waitUntil(() => active.events.filter((event) => event.kind === "error").length > activeErrors);
    await codexAdapter.send(idle, "retry saved conversation");
    if (idle.events.filter((event) => event.kind === "error").length <= errorCount) {
      throw new Error("failed resume did not surface a recoverable error");
    }
    if ((await requests()).filter((entry) => entry.method === "thread/start").length !== 2) {
      throw new Error("failed resume silently started a new conversation");
    }
    await rm(join(root, "refuse-resume"));
    await codexAdapter.send(idle, "retry saved conversation");
    if (idle.internal.threadId !== idleThread) throw new Error("resume retry lost the saved conversation ID");
    console.log("codex crash recovery assertions passed");
  } finally {
    codexStopSharedServerForTest();
  }
}

export {};
