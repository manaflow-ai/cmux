import { expect, test } from "bun:test";
import { makeAcpAdapter } from "../adapters/acp";
import type { AgentEvent, ProviderDef, SessionCtx, SessionStatus } from "../types";

test("emits ACP progress updates and terminal tool events", async () => {
  const def: ProviderDef = {
    id: "fake-acp-tool-progress",
    label: "Fake ACP Tool Progress",
    adapter: "acp",
    cmd: ["bun", `${import.meta.dir}/fake-acp-tool-progress.ts`],
  };
  const adapter = makeAcpAdapter(def);
  const events: AgentEvent[] = [];
  const sess: SessionCtx = {
    id: "fake-tool-progress-session",
    provider: def.id,
    cwd: `${import.meta.dir}/../scratch`,
    title: "fake ACP tool progress",
    autoApprove: true,
    startOptions: {},
    status: "idle",
    events,
    internal: {},
    emit(evt: AgentEvent) { events.push(evt); },
    setStatus(status: SessionStatus) { this.status = status; },
  };

  try {
    await adapter.send(sess, "show progress");
    expect(events.filter((event) => event.kind === "tool-start")).toEqual([
      { kind: "tool-start", toolId: "progress", name: "Long task", detail: "src/work.ts" },
      { kind: "tool-start", toolId: "failure", name: "Failing task", detail: "src/fail.ts" },
    ]);
    expect(events.filter((event) => event.kind === "tool-update")).toEqual([
      { kind: "tool-update", toolId: "progress", out: "step 1" },
      { kind: "tool-update", toolId: "progress", name: "Long task (still running)", out: "diff src/work.ts (+1/-1) new line" },
      { kind: "tool-update", toolId: "failure", out: "checking" },
    ]);
    expect(events.filter((event) => event.kind === "tool-end")).toEqual([
      { kind: "tool-end", toolId: "progress", ok: true, detail: "terminal term-42" },
      { kind: "tool-end", toolId: "failure", ok: false, detail: "exit 1" },
    ]);
  } finally {
    adapter.dispose(sess);
  }
});
