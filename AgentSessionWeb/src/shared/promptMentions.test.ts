import { expect, test } from "bun:test";
import { promptMentionMarkdown } from "./promptMentions";

test("prompt mention serialization matches Codex markdown links", () => {
  expect(promptMentionMarkdown({
    kind: "at",
    label: "cmux",
    name: "cmux",
    path: "/Users/lawrence/fun/cmuxterm-hq",
  })).toBe("[cmux](/Users/lawrence/fun/cmuxterm-hq)");

  expect(promptMentionMarkdown({
    displayName: "Codex",
    kind: "agent",
    name: "codex",
    path: "provider://codex",
  })).toBe("[@Codex](provider://codex)");

  expect(promptMentionMarkdown({
    kind: "skill",
    name: "codex-review",
    path: "skill://codex-review",
  })).toBe("[$codex-review](skill://codex-review)");
});

test("prompt mention serialization escapes markdown labels and destinations", () => {
  expect(promptMentionMarkdown({
    kind: "at",
    label: "work [tree]",
    name: "work [tree]",
    path: "/tmp/work tree/(current)",
  })).toBe("[work \\[tree\\]](/tmp/work%20tree/\\(current\\))");
});
