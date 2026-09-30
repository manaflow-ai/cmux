import { readFile, rm, writeFile } from "node:fs/promises";
import { expect, test } from "bun:test";
import { makeAcpAdapter } from "../adapters/acp";
import type { AgentEvent, ProviderDef, SessionCtx, SessionStatus } from "../types";

const fakeCommand = ["bun", `${import.meta.dir}/fake-acp-stop.ts`];

function makeSession(id: string, events: AgentEvent[]): SessionCtx {
  return {
    id,
    provider: "fake-acp-stop",
    cwd: `${import.meta.dir}/../scratch`,
    title: "fake ACP stop",
    autoApprove: true,
    startOptions: {},
    status: "idle",
    events,
    internal: {},
    emit(evt: AgentEvent) {
      events.push(evt);
    },
    setStatus(status: SessionStatus) {
      this.status = status;
    },
  };
}

async function waitFor(path: string, predicate: (value: string) => boolean, label: string) {
  for (let attempt = 0; attempt < 200; attempt++) {
    try {
      const value = await readFile(path, "utf8");
      if (predicate(value)) return;
    } catch {
      // The fake has not created the marker yet.
    }
    await Bun.sleep(10);
  }
  throw new Error(`timed out waiting for ${label}`);
}

async function lines(path: string): Promise<string[]> {
  try {
    return (await readFile(path, "utf8")).split("\n").filter(Boolean);
  } catch {
    return [];
  }
}

async function withFake(name: string, body: (paths: Record<string, string>) => Promise<void>) {
  const root = `${import.meta.dir}/../scratch/acp-stop-${name}-${process.pid}-${Date.now()}`;
  const paths = {
    startupGate: `${root}-startup-gate`,
    startupReady: `${root}-startup-ready`,
    promptGate: `${root}-prompt-gate`,
    promptLog: `${root}-prompts.log`,
  };
  try {
    await body(paths);
  } finally {
    await Promise.all(Object.values(paths).map((path) => rm(path, { force: true })));
  }
}

function makeAdapter(paths: Record<string, string>) {
  const def: ProviderDef = {
    id: "fake-acp-stop",
    label: "Fake ACP Stop",
    adapter: "acp",
    cmd: [
      ...fakeCommand,
      "--startup-gate", paths.startupGate,
      "--startup-ready", paths.startupReady,
      "--prompt-gate", paths.promptGate,
      "--prompt-log", paths.promptLog,
    ],
  };
  return makeAcpAdapter(def);
}

test("Stop cancels an ACP turn queued behind a running turn", async () => {
  await withFake("queued", async (paths) => {
    await writeFile(paths.startupGate, "release\n");
    const adapter = makeAdapter(paths);
    const events: AgentEvent[] = [];
    const sess = makeSession("queued-stop", events);
    try {
      const first = adapter.send(sess, "first");
      await waitFor(paths.promptLog, (value) => value.includes("first\n"), "first prompt");
      const queued = adapter.send(sess, "queued");
      adapter.stop(sess);
      await writeFile(paths.promptGate, "release\n");
      await Promise.all([first, queued]);

      expect(await lines(paths.promptLog)).toEqual(["first"]);
      expect(events.filter((event) => event.kind === "done")).toHaveLength(2);
      expect(sess.status).toBe("idle");
    } finally {
      adapter.dispose(sess);
    }
  });
});

test("Stop cancels an ACP turn during startup", async () => {
  await withFake("startup", async (paths) => {
    const adapter = makeAdapter(paths);
    const events: AgentEvent[] = [];
    const sess = makeSession("startup-stop", events);
    try {
      const turn = adapter.send(sess, "startup");
      await waitFor(paths.startupReady, (value) => value.includes("ready\n"), "startup");
      adapter.stop(sess);
      await writeFile(paths.startupGate, "release\n");
      await writeFile(paths.promptGate, "release\n");
      await turn;

      expect(await lines(paths.promptLog)).toEqual([]);
      expect(events.filter((event) => event.kind === "done")).toHaveLength(1);
      expect(sess.status).toBe("idle");
    } finally {
      adapter.dispose(sess);
    }
  });
});

test("a new ACP turn after Stop still reaches the agent", async () => {
  await withFake("after-stop", async (paths) => {
    await writeFile(paths.startupGate, "release\n");
    const adapter = makeAdapter(paths);
    const events: AgentEvent[] = [];
    const sess = makeSession("after-stop", events);
    try {
      const first = adapter.send(sess, "first");
      await waitFor(paths.promptLog, (value) => value.includes("first\n"), "first prompt");
      const queued = adapter.send(sess, "queued");
      adapter.stop(sess);
      const afterStop = adapter.send(sess, "after-stop");
      await writeFile(paths.promptGate, "release\n");
      await Promise.all([first, queued, afterStop]);

      expect(await lines(paths.promptLog)).toEqual(["first", "after-stop"]);
      expect(events.filter((event) => event.kind === "done")).toHaveLength(3);
      expect(sess.status).toBe("idle");
    } finally {
      adapter.dispose(sess);
    }
  });
});
