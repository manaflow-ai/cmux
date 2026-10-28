import { expect, test } from "bun:test";
import { toolDetailHoverTitle } from "../src/toolDetail";

test("long tool commands keep their full text in a hover title", () => {
  const command = "pnpm test --filter @cmux/webviews -- --runInBand --reporter=verbose";
  expect(toolDetailHoverTitle(command)).toBe(command);
});

test("empty tool details do not create an empty tooltip", () => {
  expect(toolDetailHoverTitle("   ")).toBeUndefined();
  expect(toolDetailHoverTitle(undefined)).toBeUndefined();
});
