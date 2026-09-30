import assert from "node:assert/strict";
import { watch } from "node:fs";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { cmuxRpc } from "../cmux-rpc";

const originalCli = process.env.CMUX_BUNDLED_CLI_PATH;
const timeoutDescriptor = Object.getOwnPropertyDescriptor(globalThis, "setTimeout")!;
const clearDescriptor = Object.getOwnPropertyDescriptor(globalThis, "clearTimeout")!;
const originalSetTimeout = globalThis.setTimeout;
const originalClearTimeout = globalThis.clearTimeout;
const deadlines = new Map<number, () => void>();
let nextDeadline = -1;
Object.defineProperty(globalThis, "setTimeout", { ...timeoutDescriptor, value(run: () => void, delay: number, ...args: any[]) {
  if (delay === 10_000) { const id = nextDeadline--; deadlines.set(id, run); return id; }
  return originalSetTimeout(run, delay, ...args);
} });
Object.defineProperty(globalThis, "clearTimeout", { ...clearDescriptor, value(id: any) {
  if (deadlines.delete(id)) return;
  originalClearTimeout(id);
} });
async function bounded<T>(promise: Promise<T>, message: string, ms = 2_000): Promise<T> {
  let timer: ReturnType<typeof setTimeout>;
  try {
    return await Promise.race([promise, new Promise<never>((_, reject) => {
      timer = originalSetTimeout(() => reject(new Error(message)), ms);
    })]);
  } finally { originalClearTimeout(timer!); }
}
async function fileReady(path: string): Promise<void> {
  const directory = join(path, "..");
  let watcher: ReturnType<typeof watch>;
  let checking = false;
  try {
    await bounded(new Promise<void>((resolve) => {
      const check = async () => {
        if (checking) return;
        checking = true;
        try { await readFile(path); resolve(); } catch {}
        finally { checking = false; }
      };
      watcher = watch(directory, () => { void check(); });
      void check();
    }), "owned CLI fixture did not become ready");
  } finally { watcher!?.close(); }
}

let root: string | undefined;
try {
  const scratch = join(import.meta.dir, "../scratch");
  await mkdir(scratch, { recursive: true });
  root = await mkdtemp(join(scratch, "rpc-deadline-"));
  const cli = join(root, "cmux-fixture");
  await writeFile(cli, `#!${process.execPath}\n` + await readFile(join(import.meta.dir, "fake-cmux-rpc.ts"), "utf8"));
  await chmod(cli, 0o755);
  process.env.CMUX_BUNDLED_CLI_PATH = cli;
  for (const mode of ["ignore-term", "hold-pipes"]) {
    const params = { mode, ready: join(root, `${mode}.ready`), exit: join(root, `${mode}.exit`), done: join(root, `${mode}.done`) };
    const request = cmuxRpc("surface.focus", params);
    try {
      await fileReady(params.ready);
      assert.equal(deadlines.size, 1);
      const expire = [...deadlines.values()][0];
      expire();
      const result = await bounded(request, "RPC deadline must return even when the CLI ignores termination or output pipes stay open", 200);
      assert.equal(result.ok, false, "an expired RPC must report failure");
      assert.equal((result as any).errorCode, "timeout");
      assert.equal(deadlines.size, 0);
    } finally {
      // Old implementations can still be waiting on this fixture. The owned
      // shutdown file releases it without signalling any user process.
      await writeFile(params.exit, "exit");
      if (mode === "hold-pipes") await fileReady(params.done);
      await bounded(request.catch(() => {}), "owned CLI fixture did not shut down");
    }
  }
  assert.deepEqual(await cmuxRpc("mobile.chat.send", { mode: "json", value: "expected-value" }), {
    ok: true, result: { method: "mobile.chat.send", text: "猫🙂", value: "expected-value" },
  });
  assert.deepEqual(await cmuxRpc("surface.focus", { mode: "text" }), { ok: true, result: "plain response" });
  const failure = await cmuxRpc("mobile.chat.interrupt", { mode: "failure" });
  assert.equal(failure.ok, false);
  assert.equal(failure.error?.length, 300);
  assert.ok(failure.error?.startsWith("controlled failure"));
  assert.equal(deadlines.size, 0);
  console.log("RPC deadlines return through ignored termination and inherited pipes; normal JSON, UTF-8, text, and failures remain intact: OK");
} finally {
  if (originalCli === undefined) delete process.env.CMUX_BUNDLED_CLI_PATH;
  else process.env.CMUX_BUNDLED_CLI_PATH = originalCli;
  Object.defineProperty(globalThis, "setTimeout", timeoutDescriptor);
  Object.defineProperty(globalThis, "clearTimeout", clearDescriptor);
  if (root) await rm(root, { recursive: true, force: true });
}
