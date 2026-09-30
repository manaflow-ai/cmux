import { expect, test } from "bun:test";
import { makeAcpAdapter } from "../adapters/acp";
import type { AgentEvent, ProviderDef, SessionCtx, SessionStatus } from "../types";

test("shows ACP tool locations and every tool output variant", async () => {
  const def: ProviderDef = {
    id: "fake-acp-tool-detail",
    label: "Fake ACP Tool Detail",
    adapter: "acp",
    cmd: ["bun", `${import.meta.dir}/fake-acp-tool-detail.ts`],
  };
  const adapter = makeAcpAdapter(def);
  const events: AgentEvent[] = [];
  const sess: SessionCtx = {
    id: "fake-tool-detail-session",
    provider: def.id,
    cwd: `${import.meta.dir}/../scratch`,
    title: "fake ACP tool detail",
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

  try {
    await adapter.send(sess, "show tool details");

    const starts = events.filter((event) => event.kind === "tool-start");
    expect(starts).toEqual([
      { kind: "tool-start", toolId: "located", name: "Edit files", detail: "src/one.ts, src/two.ts" },
      { kind: "tool-start", toolId: "raw-input", name: "Inspect files", detail: '{"command":"cat README.md"}' },
    ]);

    const ends = events.filter((event) => event.kind === "tool-end");
    expect(ends.find((event) => event.toolId === "new-file")?.detail).toContain("src/new.ts");
    expect(ends.find((event) => event.toolId === "new-file")?.detail).toContain("+2/-0");
    expect(ends.find((event) => event.toolId === "new-file")?.detail).toContain("one two");

    expect(ends.find((event) => event.toolId === "changed-file")?.detail).toContain("src/changed.ts");
    expect(ends.find((event) => event.toolId === "changed-file")?.detail).toContain("+2/-1");

    const mixed = ends.find((event) => event.toolId === "mixed")?.detail ?? "";
    expect(mixed).toContain("text output");
    expect(mixed).toContain("src/mixed.ts");
    expect(mixed).toContain("term-42");
  } finally {
    adapter.dispose(sess);
  }
});
