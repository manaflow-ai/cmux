import { expect, test } from "bun:test";
import { makeAcpAdapter } from "../adapters/acp";
import { mergeRemoteModelOptionsForTest, minimaxProviderForTest, sanitizeStartOptions } from "../server";
import type { AgentEvent, SessionCtx } from "../types";

for (const selected of [undefined, "MiniMax-M3.1-Flash", "MiniMax-M3", "MiniMax-M2.7", "custom-model"]) {
  test(`MiniMax ACP serializes ${selected ?? "default"} and preserves successive prompts`, async () => {
    const def = { ...minimaxProviderForTest(), cmd: [process.execPath, `${import.meta.dir}/fake-minimax-acp.ts`] };
    const adapter = makeAcpAdapter(def);
    const events: AgentEvent[] = [];
    const session: SessionCtx = {
      id: "offline", provider: "minimax", cwd: import.meta.dir, title: "offline",
      autoApprove: false, startOptions: await sanitizeStartOptions("minimax", import.meta.dir, selected ? { model: selected } : {}),
      status: "idle", events, internal: {},
      emit(event) { events.push(event); },
      setStatus(status) { this.status = status; },
    };
    try {
      await adapter.send(session, "first prompt");
      await adapter.send(session, "second prompt");
      expect(events.filter((event) => event.kind === "error")).toEqual([]);
      const deltas = events.filter((event) => event.kind === "delta");
      const wire = JSON.parse(deltas.at(-1)!.text);
      expect(wire.model).toBe(selected ?? "MiniMax-M3.1-Flash");
      expect(wire.prompts).toEqual([
        { sessionId: "offline-minimax", prompt: [{ type: "text", text: "first prompt" }] },
        { sessionId: "offline-minimax", prompt: [{ type: "text", text: "second prompt" }] },
      ]);
      const options = events.filter((event) => event.kind === "options").at(-1)!.options;
      expect(options.find((option) => option.id === "model")?.value).toBe(wire.model);
      expect(options.find((option) => option.id === "model")?.choices?.map((choice) => choice.value)).toEqual([
        "MiniMax-M3.1-Flash", "MiniMax-M3",
        ...(["MiniMax-M2.7", "custom-model"].includes(selected ?? "") ? [selected] : []),
      ]);
      expect(options.find((option) => option.id === "effort")?.value).toBe("max");
    } finally {
      adapter.dispose(session);
    }
  });
}

test("MiniMax catalog refresh filters legacy choices without resetting an explicit selection", () => {
  const options = mergeRemoteModelOptionsForTest("minimax", [{
    id: "model", label: "Model", kind: "select", value: "custom-model",
    choices: [{ value: "MiniMax-M2.7", label: "Legacy" }],
  }], { defaultModel: "MiniMax-M2.7", models: [{ id: "MiniMax-M2.7", label: "Legacy" }] });
  expect(options[0]?.value).toBe("custom-model");
  expect(options[0]?.choices?.map((choice) => choice.value)).toEqual([
    "MiniMax-M3.1-Flash", "MiniMax-M3", "custom-model",
  ]);
});
