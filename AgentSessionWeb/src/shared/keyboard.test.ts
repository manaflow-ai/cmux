import { expect, test } from "bun:test";
import { isComposingEnter } from "./keyboard";

test("composing enter is detected from browser and editor composition state", () => {
  expect(isComposingEnter({ key: "Enter", isComposing: true })).toBe(true);
  expect(isComposingEnter({ key: "Enter" }, true)).toBe(true);
  expect(isComposingEnter({ key: "Enter", keyCode: 229 })).toBe(true);
});

test("non-composing enter remains submittable", () => {
  expect(isComposingEnter({ key: "Enter" })).toBe(false);
  expect(isComposingEnter({ key: "a", isComposing: true })).toBe(false);
});
