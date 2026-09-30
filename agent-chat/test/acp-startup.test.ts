import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { makeAcpAdapter } from "../adapters/acp";
import type { AgentEvent, SessionCtx } from "../types";

const directory = mkdtempSync(join(import.meta.dir, ".acp-startup-"));
const adapter = makeAcpAdapter({
  id: "fixture-acp-startup", label: "Fixture ACP", adapter: "acp",
  cmd: [process.execPath, join(import.meta.dir, "fake-acp-startup.ts"), directory],
});
const events: AgentEvent[] = [];
const sess: SessionCtx = {
  id: "fixture", provider: "fixture-acp-startup", cwd: directory, title: "Fixture",
  autoApprove: false, startOptions: {}, status: "idle", events, internal: {},
  emit(event) { events.push(event); },
  setStatus(status) { this.status = status; },
};

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

async function bounded<T>(promise: Promise<T>): Promise<T> {
  let timer: ReturnType<typeof setTimeout>;
  try {
    return await Promise.race([promise, new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error("ACP startup did not settle after its 30s timeout")), 35_000);
    })]);
  } finally { clearTimeout(timer!); }
}

try {
  assert.ok(adapter.refreshOptions);
  const modes = ["reject-initialize", "reject-session", "hang-initialize", "hang-session"];
  for (const [index, mode] of modes.entries()) {
    writeFileSync(join(directory, "mode"), mode);
    const offset = events.length;
    // Sending a prompt and refreshing options must share one startup. Both
    // paths must settle after cleanup, and sending must return the chat to idle.
    const results = await bounded(Promise.allSettled([
      Promise.resolve(adapter.send(sess, "fixture prompt")), adapter.refreshOptions(sess),
    ]));
    assert.equal(results[0]!.status, "fulfilled");
    assert.equal(results[1]!.status, "rejected");
    const diagnostic = mode.startsWith("hang") ? /did not finish ACP startup within 30s/ : new RegExp(`fixture ${mode.slice(7)} rejected`);
    if (results[1]!.status === "rejected") assert.match(String(results[1]!.reason), diagnostic);
    const turnEvents = events.slice(offset);
    const errors = turnEvents.filter((event) => event.kind === "error");
    assert.equal(errors.length, 1);
    assert.match(errors[0]!.message, diagnostic);
    assert.equal(turnEvents.filter((event) => event.kind === "done").length, 1);
    assert.equal(turnEvents.filter((event) => event.kind === "meta").length, 0);
    assert.equal(sess.status, "idle");
    assert.equal(sess.internal.acp, undefined);
    assert.equal(sess.internal.acpStarting, undefined);
    assert.equal(sess.internal.acpStartingProc, undefined);
    assert.equal(processes().length, index + 1, "concurrent callers must share one startup");
    assert.ok(processes().every((child) => !alive(child.pid)), "failed ACP startup must reap its child before returning");
    assert.equal(existsSync(join(directory, "prompts.jsonl")), false, "failed startup must not deliver a prompt");
  }

  writeFileSync(join(directory, "mode"), "accept");
  await bounded(Promise.resolve(adapter.send(sess, "successful retry")));
  const children = processes();
  assert.equal(children.length, 5);
  assert.equal(alive(children[4]!.pid), true, "successful startup must keep the agent alive");
  assert.equal(sess.status, "idle");
  await adapter.refreshOptions(sess);
  await adapter.send(sess, "reused agent");
  assert.equal(processes().length, 5, "successful startup must be reused");
  const prompts = readFileSync(join(directory, "prompts.jsonl"), "utf8").trim().split("\n").map((line) => JSON.parse(line));
  assert.deepEqual(prompts.map((prompt) => prompt.prompt[0].text), ["successful retry", "reused agent"]);
  assert.ok(prompts.every((prompt) => prompt.sessionId === `fixture-${children[4]!.pid}`));
  console.log("ACP startup rejection/timeout cleanup, idle recovery, single-flight and successful retry: OK");
} finally {
  adapter.dispose(sess);
  const children = processes();
  // Cleanup is restricted to the PIDs recorded by this disposable fixture.
  for (const child of children) if (alive(child.pid)) process.kill(child.pid, "SIGKILL");
  const deadline = Date.now() + 2_000;
  while (children.some((child) => alive(child.pid)) && Date.now() < deadline) await Bun.sleep(10);
  rmSync(directory, { recursive: true, force: true });
  assert.ok(children.every((child) => !alive(child.pid)), "the fixture must leave no child processes behind");
}
