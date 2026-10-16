import { expect, test } from "bun:test";
import type { Block } from "../src/session";

Object.defineProperty(globalThis, "location", {
  configurable: true,
  value: { pathname: "/" },
});

const { activityTailKey } = await import("../src/activity");
const { foldEvent } = await import("../src/session");
const { groupTurns } = await import("../src/turns");

const firstPlan = {
  kind: "plan" as const,
  entries: [{ text: "First turn", status: "in_progress" as const }],
};

test("keeps plans in the turn where they arrive", () => {
  const secondPlan = { kind: "plan" as const, entries: [{ text: "Second turn", status: "pending" as const }] };
  const finalPlan = { kind: "plan" as const, entries: [{ text: "Second turn, updated", status: "completed" as const }] };
  let blocks = foldEvent([], firstPlan);
  blocks = foldEvent(blocks, { kind: "user", text: "next turn" });
  blocks = foldEvent(blocks, secondPlan);
  blocks = foldEvent(blocks, finalPlan);
  const groups = groupTurns(blocks);

  expect(groups).toHaveLength(2);
  expect(groups.map((group) => group.activity.filter((block) => block.kind === "plan").length)).toEqual([1, 1]);
  expect(groups[0]?.activity).toContainEqual(firstPlan);
  expect(groups[1]?.activity).toContainEqual(finalPlan);
  expect(groups[1]?.activity).not.toContainEqual(secondPlan);
});

test("refreshes the activity key when a plan entry changes status", () => {
  const pending = [{ kind: "plan" as const, entries: [{ text: "long text that is not part of the key", status: "pending" as const }] }];
  const inProgress = [{ kind: "plan" as const, entries: [{ text: "a different long text", status: "in_progress" as const }] }];

  expect(activityTailKey(pending)).not.toBe(activityTailKey(inProgress));
});

test("collapses repeated plans within one turn", () => {
  const updates = ["pending", "in_progress", "completed"].map((status) => ({
    kind: "plan" as const,
    entries: [{ text: "one turn", status: status as "pending" | "in_progress" | "completed" }],
  }));
  const blocks = updates.reduce<Block[]>((current, update) => foldEvent(current, update), []);

  expect(blocks.filter((block) => block.kind === "plan")).toHaveLength(1);
  expect(blocks[0]).toEqual(updates[2]);
});
