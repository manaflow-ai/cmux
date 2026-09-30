import { expect, test } from "bun:test";

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
  const blocks = foldEvent(
    foldEvent(foldEvent([], firstPlan), { kind: "user", text: "next turn" }),
    { kind: "plan", entries: [{ text: "Second turn", status: "pending" }] },
  );
  const groups = groupTurns(blocks);

  expect(groups).toHaveLength(2);
  expect(groups.map((group) => group.activity.filter((block) => block.kind === "plan").length)).toEqual([1, 1]);
  expect(groups[0]?.activity).toContainEqual(firstPlan);
  expect(groups[1]?.activity).toContainEqual({
    kind: "plan",
    entries: [{ text: "Second turn", status: "pending" }],
  });
});

test("refreshes the activity key when a plan entry changes status", () => {
  const pending = [{ kind: "plan" as const, entries: [{ text: "long text that is not part of the key", status: "pending" as const }] }];
  const inProgress = [{ kind: "plan" as const, entries: [{ text: "a different long text", status: "in_progress" as const }] }];

  expect(activityTailKey(pending)).not.toBe(activityTailKey(inProgress));
});
