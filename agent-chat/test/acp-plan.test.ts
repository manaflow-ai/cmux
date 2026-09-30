import { expect, test } from "bun:test";
import { makeAcpAdapter } from "../adapters/acp";
import type { AgentEvent, ProviderDef, SessionCtx, SessionStatus } from "../types";

Object.defineProperty(globalThis, "location", {
  configurable: true,
  value: { pathname: "/" },
});

const { foldEvent } = await import("../src/session");

test("preserves ACP plans as structured, replaceable events", async () => {
  const def: ProviderDef = {
    id: "fake-acp-plan",
    label: "Fake ACP Plan",
    adapter: "acp",
    cmd: ["bun", `${import.meta.dir}/fake-acp-plan.ts`],
  };
  const adapter = makeAcpAdapter(def);
  const events: AgentEvent[] = [];
  const sess: SessionCtx = {
    id: "fake-plan-session",
    provider: def.id,
    cwd: `${import.meta.dir}/../scratch`,
    title: "fake plan",
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
    await adapter.send(sess, "show me the plan");

    const planEvents = events.filter((event) => (event as { kind: string }).kind === "plan") as Array<AgentEvent & {
      kind: "plan";
      entries: Array<{ text: string; status: string; priority?: string }>;
    }>;
    expect(planEvents).toHaveLength(2);
    expect(planEvents[0]?.entries).toEqual([
      { text: "Inspect the repository", status: "pending", priority: "high" },
      { text: "Implement the change", status: "in_progress" },
      { text: "x".repeat(350), status: "completed" },
      { text: "Unknown state stays visible", status: "unknown" },
    ]);
    expect(planEvents[1]?.entries).toEqual([
      { text: "Verify the change", status: "in_progress", priority: "medium" },
    ]);

    const blocks = planEvents.reduce((current, event) => foldEvent(current, event as never), [] as unknown[]);
    const visiblePlans = blocks.filter((block) => (block as { kind: string }).kind === "plan");
    expect(visiblePlans).toHaveLength(1);
    expect(visiblePlans[0]).toEqual({ kind: "plan", entries: planEvents[1]?.entries });
  } finally {
    adapter.dispose(sess);
  }
});
