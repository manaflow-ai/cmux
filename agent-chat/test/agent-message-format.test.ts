import { expect, test } from "bun:test";
import { agentMessageFoldedByDefault } from "../src/components/agentMessageFormat";

test("long agent messages fold while short messages stay expanded", () => {
  expect(agentMessageFoldedByDefault("short\nmessage")).toBe(false);
  expect(agentMessageFoldedByDefault(Array.from({ length: 9 }, (_, index) => `line ${index}`).join("\n"))).toBe(true);
});

