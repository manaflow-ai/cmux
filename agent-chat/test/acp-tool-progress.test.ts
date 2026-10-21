import { expect, test } from "bun:test";
import { makeAcpAdapter } from "../adapters/acp";
import type { AgentEvent, ProviderDef, SessionCtx, SessionStatus } from "../types";

test("emits intermediate ACP tool updates before the terminal event", async () => {
  const def: ProviderDef = {
    id: "fake-acp-tool-progress",
    label: "Fake ACP Tool Progress",
    adapter: "acp",
    cmd: ["bun", import.meta.dir + "/fake-acp-tool-progress.ts"],
  };
  const adapter = makeAcpAdapter(def);
  const events: AgentEvent[] = [];
  const sess: SessionCtx = {
    id: "fake-tool-progress-session",
    provider: def.id,
    cwd: import.meta.dir + "/../scratch",
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
    ]);
    expect(events.filter((event) => event.kind === "tool-update")).toEqual([
      { kind: "tool-update", toolId: "progress", out: "step 1" },
      { kind: "tool-update", toolId: "progress", out: "step 2" },
    ]);
    expect(events.filter((event) => event.kind === "tool-end")).toEqual([
      { kind: "tool-end", toolId: "progress", ok: true, detail: "finished" },
    ]);
  } finally {
    adapter.dispose(sess);
  }
});
