import { expect, test } from "bun:test";
import { foldEvent, type Block } from "../src/session";

test("folds intermediate ACP tool updates into the existing row", () => {
  let blocks: Block[] = [];
  blocks = foldEvent(blocks, { kind: "tool-start", toolId: "tool-1", name: "Edit", detail: "src/a.ts" });
  blocks = foldEvent(blocks, { kind: "tool-update", toolId: "tool-1", out: "writing line 1" });
  expect(blocks).toEqual([
    { kind: "tool", toolId: "tool-1", name: "Edit", detail: "src/a.ts", status: "running", out: "writing line 1" },
  ]);

  blocks = foldEvent(blocks, { kind: "tool-update", toolId: "tool-1", out: "writing line 2" });
  expect(blocks).toEqual([
    { kind: "tool", toolId: "tool-1", name: "Edit", detail: "src/a.ts", status: "running", out: "writing line 2" },
  ]);

  blocks = foldEvent(blocks, { kind: "tool-end", toolId: "tool-1", ok: true, detail: "done" });
  expect(blocks).toEqual([
    { kind: "tool", toolId: "tool-1", name: "Edit", detail: "src/a.ts", status: "ok", out: "done" },
  ]);
});

test("folds failed tool updates without duplicating rows", () => {
  let blocks: Block[] = [];
  blocks = foldEvent(blocks, { kind: "tool-start", toolId: "tool-2", name: "Shell" });
  blocks = foldEvent(blocks, { kind: "tool-update", toolId: "tool-2", out: "running" });
  blocks = foldEvent(blocks, { kind: "tool-end", toolId: "tool-2", ok: false, detail: "exit 1" });
  expect(blocks).toEqual([
    { kind: "tool", toolId: "tool-2", name: "Shell", status: "fail", out: "exit 1" },
  ]);
});

test("ignores late or unknown tool updates", () => {
  let blocks: Block[] = [];
  blocks = foldEvent(blocks, { kind: "tool-start", toolId: "tool-3", name: "Read", detail: "README.md" });
  blocks = foldEvent(blocks, { kind: "tool-end", toolId: "tool-3", ok: true, detail: "done" });
  const completed = [...blocks];
  expect(foldEvent(blocks, { kind: "tool-update", toolId: "tool-3", out: "late" })).toEqual(completed);
  expect(foldEvent(blocks, { kind: "tool-update", toolId: "missing", out: "ignored" })).toEqual(completed);
});
