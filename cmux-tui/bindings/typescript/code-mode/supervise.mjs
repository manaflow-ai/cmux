import { mkdtemp, realpath, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { watchOwnerTurn } from "./owner-lifecycle.mjs";

// One deadline for CLI and MCP calls, measured outside the sandbox so a tight
// JavaScript loop cannot starve the timer. No zero/unbounded or overflowing timer.
export const DEFAULT_TIMEOUT_MS = 30_000;
export function timeoutMs(value = DEFAULT_TIMEOUT_MS) {
  const number = typeof value === "string" && /^\d+$/.test(value) ? Number(value) : value;
  if (!Number.isSafeInteger(number) || number < 1 || number > 2_147_483_647) {
    throw new Error("timeout_ms must be an integer from 1 to 2147483647");
  }
  return number;
}

async function supervise(worker, args) {
  const limit = timeoutMs(process.env.CMUX_CODE_MODE_TIMEOUT_MS);
  const controller = new AbortController();
  let child;
  let killTimer;
  let directory;
  let unwatch = () => {};
  let outcome;
  const killGroup = () => {
    if (child) {
      try { process.kill(-child.pid, "SIGKILL"); } catch {}
    }
  };
  const stop = (reason, code = 130) => {
    if (outcome) return;
    outcome = { reason, code };
    controller.abort();
    if (child) {
      // Signal only the shell first, letting it kill/reap the sandbox and
      // relays. A stuck worker gets one bounded escalation of its owned group.
      child.kill("SIGTERM");
      killTimer = setTimeout(killGroup, 250);
    }
  };
  const onTerm = () => stop("cancelled", 143);
  const onInt = () => stop("cancelled", 130);
  process.on("SIGTERM", onTerm);
  process.on("SIGINT", onInt);
  // Synchronous exit cleanup also covers uncaught failures in this host process.
  process.on("exit", killGroup);
  const deadline = setTimeout(() => stop(`run limit exceeded (${limit} ms)`, 124), limit);
  try {
    unwatch = await watchOwnerTurn(process.env, (reason) => stop(reason), controller.signal);
    if (!outcome) {
      directory = await mkdtemp(join(tmpdir(), "cmux-code-mode-proxy."));
      const proxyDirectory = await realpath(directory);
      if (!outcome) {
        child = Bun.spawn([worker, ...args], {
          detached: true,
          env: { ...process.env, CMUX_CODE_MODE_PROXY_DIR: proxyDirectory },
          stdin: "inherit", stdout: "inherit", stderr: "inherit",
        });
        const code = await child.exited;
        if (!outcome) return code;
      }
    }
  } catch (error) {
    if (!outcome) throw error;
  } finally {
    clearTimeout(deadline);
    clearTimeout(killTimer);
    unwatch();
    // Natural completion must not leave a helper alive either. The shell,
    // bwrap and payload share this detached group (no nested --new-session).
    // bwrap's isolated PID namespace and --die-with-parent are additional
    // containment, never the only cleanup for the script.
    killGroup();
    if (directory) await rm(directory, { recursive: true, force: true });
    process.off("SIGTERM", onTerm);
    process.off("SIGINT", onInt);
    process.off("exit", killGroup);
  }
  console.error(`cmux run: ${outcome.reason}`);
  return outcome.code;
}

if (import.meta.main) {
  try {
    const [worker, ...args] = Bun.argv.slice(2);
    process.exitCode = await supervise(worker, args);
  } catch (error) {
    console.error(`cmux run: ${error.message}`);
    process.exitCode = 2;
  }
}
