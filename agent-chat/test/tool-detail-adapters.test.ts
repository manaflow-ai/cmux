import { expect, test } from "bun:test";
import { claudeToolActivity } from "../adapters/claude";
import { codexCommandActivity } from "../adapters/codex";
import { activityRowHoverTitle, activityRowLabel } from "../src/turns";

test("Claude shell tool preserves description and the full command for the row", () => {
  const command = "echo " + "x".repeat(260);
  const activity = claudeToolActivity("Bash", { command, description: "Run the generated fixture" });
  expect(activity.detail).toBe(command);
  expect(activity.description).toBe("Run the generated fixture");
  expect(activityRowLabel({ kind: "tool", toolId: "claude", name: activity.name, detail: activity.detail, description: activity.description, status: "running" })).toBe("Run the generated fixture");
  expect(activityRowHoverTitle({ kind: "tool", toolId: "claude", name: activity.name, detail: activity.detail, description: activity.description, status: "running" })).toBe(command);
});

test("Codex shell activity keeps a long command suffix for hover", () => {
  const command = "printf '" + "y".repeat(260) + "'";
  const activity = codexCommandActivity({ command, description: "Print the fixture" });
  expect(activity.detail).toBe(command);
  expect(activity.description).toBe("Print the fixture");
});
