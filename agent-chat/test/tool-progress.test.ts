import { expect, test } from "bun:test";
import type { Block } from "../src/session";
import type { AgentEvent } from "../types";

Object.defineProperty(globalThis, "location", {
  configurable: true,
  value: { pathname: "/" },
});

const { foldEvent } = await import("../src/session");

function update(toolId: string, fields: Record<string, string>) {
  return { kind: "tool-update", toolId, ...fields } as Extract<AgentEvent, { kind: "tool-update" }>;
}

test("folds repeated progress into one running tool row", () => {
  let blocks: Block[] = [];
  blocks = foldEvent(blocks, { kind: "tool-start", toolId: "tool-1", name: "Edit", detail: "src/a.ts" });
  blocks = foldEvent(blocks, update("tool-1", { out: "writing line 1" }));
  expect(blocks).toEqual([
    { kind: "tool", toolId: "tool-1", name: "Edit", detail: "src/a.ts", status: "running", out: "writing line 1" },
  ]);

  blocks = foldEvent(blocks, update("tool-1", { out: "writing line 2" }));
  expect(blocks).toEqual([
    { kind: "tool", toolId: "tool-1", name: "Edit", detail: "src/a.ts", status: "running", out: "writing line 2" },
  ]);
});

test("keeps tool ordering and ignores updates after completion", () => {
  let blocks: Block[] = [];
  blocks = foldEvent(blocks, { kind: "tool-start", toolId: "tool-1", name: "Edit" });
  blocks = foldEvent(blocks, { kind: "tool-start", toolId: "tool-2", name: "Shell" });
  blocks = foldEvent(blocks, update("tool-1", { name: "Edit file", out: "diff src/a.ts" }));
  expect(blocks.map((block) => block.kind === "tool" ? [block.toolId, block.name, block.out] : block.kind)).toEqual([
    ["tool-1", "Edit file", "diff src/a.ts"],
    ["tool-2", "Shell", undefined],
  ]);

  blocks = foldEvent(blocks, { kind: "tool-end", toolId: "tool-1", ok: true, detail: "done" });
  const completed = [...blocks];
  expect(foldEvent(blocks, update("tool-1", { out: "late output" }))).toEqual(completed);
});

test("retains the final output for successful and failed tools", () => {
  let blocks: Block[] = [];
  blocks = foldEvent(blocks, { kind: "tool-start", toolId: "ok-tool", name: "Build", detail: "package" });
  blocks = foldEvent(blocks, update("ok-tool", { out: "compiling" }));
  blocks = foldEvent(blocks, { kind: "tool-end", toolId: "ok-tool", ok: true, detail: "finished" });
  blocks = foldEvent(blocks, { kind: "tool-start", toolId: "failed-tool", name: "Test" });
  blocks = foldEvent(blocks, update("failed-tool", { out: "running tests" }));
  blocks = foldEvent(blocks, { kind: "tool-end", toolId: "failed-tool", ok: false, detail: "exit 1" });

  expect(blocks).toEqual([
    { kind: "tool", toolId: "ok-tool", name: "Build", detail: "package", status: "ok", out: "finished" },
    { kind: "tool", toolId: "failed-tool", name: "Test", status: "fail", out: "exit 1" },
  ]);
  expect(foldEvent(blocks, update("missing", { out: "ignored" }))).toEqual(blocks);
});
