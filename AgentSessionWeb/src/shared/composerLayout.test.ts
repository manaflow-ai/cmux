import { expect, test } from "bun:test";
import { shouldUseSingleLineComposer } from "./composerLayout";

test("composer auto layout stays single line before measurements are available", () => {
  expect(shouldUseSingleLineComposer({
    composerLayoutMode: "auto-single-line",
    hasVisibleAttachments: false,
    isEditorMultiline: false,
    isVoiceLayoutActive: false,
    singleLineInputWidth: null,
    singleLineTextWidth: 0,
  })).toBe(true);
});

test("composer auto layout expands for multiline or attachment states", () => {
  const base = {
    composerLayoutMode: "auto-single-line" as const,
    hasVisibleAttachments: false,
    isEditorMultiline: false,
    isVoiceLayoutActive: false,
    singleLineInputWidth: 240,
    singleLineTextWidth: 80,
  };

  expect(shouldUseSingleLineComposer({ ...base, isEditorMultiline: true })).toBe(false);
  expect(shouldUseSingleLineComposer({ ...base, hasVisibleAttachments: true })).toBe(false);
  expect(shouldUseSingleLineComposer({ ...base, isVoiceLayoutActive: true })).toBe(false);
});

test("composer auto layout expands when text no longer fits", () => {
  const base = {
    composerLayoutMode: "auto-single-line" as const,
    hasVisibleAttachments: false,
    isEditorMultiline: false,
    isVoiceLayoutActive: false,
    singleLineInputWidth: 240,
    singleLineTextWidth: 208,
  };

  expect(shouldUseSingleLineComposer(base)).toBe(true);
  expect(shouldUseSingleLineComposer({ ...base, singleLineTextWidth: 209 })).toBe(false);
});

test("composer auto layout can return to single line after resize", () => {
  const base = {
    composerLayoutMode: "auto-single-line" as const,
    hasVisibleAttachments: false,
    isEditorMultiline: false,
    isVoiceLayoutActive: false,
    singleLineTextWidth: 320,
  };

  expect(shouldUseSingleLineComposer({ ...base, singleLineInputWidth: 300 })).toBe(false);
  expect(shouldUseSingleLineComposer({ ...base, singleLineInputWidth: 380 })).toBe(true);
});

test("composer multiline mode never uses the single-line shell", () => {
  expect(shouldUseSingleLineComposer({
    composerLayoutMode: "multiline",
    hasVisibleAttachments: false,
    isEditorMultiline: false,
    isVoiceLayoutActive: false,
    singleLineInputWidth: null,
    singleLineTextWidth: 0,
  })).toBe(false);
});
