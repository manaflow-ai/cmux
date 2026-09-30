// The plugin half: what the transcript actually renders. A reference only
// becomes a link in ordinary prose. Code spans, fenced code and text that is
// already inside a link are left exactly as written, because in those places
// the characters are the content.
import { describe, expect, test } from "bun:test";
import { linkifyGitHubReferences } from "../src/githubReferences";

const SLUG = "manaflow-ai/cmux";

function html(markdown: string, slug: string | null = SLUG): string {
  return linkifyGitHubReferences(markdown, slug);
}

describe("linkifyGitHubReferences", () => {
  test("links a bare reference in prose", () => {
    expect(html("see #847 for the tracker")).toBe(
      'see [#847](https://github.com/manaflow-ai/cmux/issues/847) for the tracker'
    );
  });

  test("keeps the punctuation it trimmed outside the link", () => {
    expect(html("landed in (#847).")).toBe(
      'landed in ([#847](https://github.com/manaflow-ai/cmux/issues/847)).'
    );
  });

  test("leaves a code span alone", () => {
    expect(html("run `grep #847 log`")).toBe("run `grep #847 log`");
  });

  test("leaves a fenced block alone", () => {
    const text = "before #847\n```\n#847 inside\n```\nafter #847";
    expect(html(text)).toBe(
      "before [#847](https://github.com/manaflow-ai/cmux/issues/847)\n" +
      "```\n#847 inside\n```\n" +
      "after [#847](https://github.com/manaflow-ai/cmux/issues/847)"
    );
  });

  test("leaves an existing markdown link alone", () => {
    const text = "[the tracker](https://github.com/manaflow-ai/cmux/issues/847) and #847";
    expect(html(text)).toBe(
      "[the tracker](https://github.com/manaflow-ai/cmux/issues/847) and " +
      "[#847](https://github.com/manaflow-ai/cmux/issues/847)"
    );
  });

  test("leaves a bare URL alone", () => {
    expect(html("https://github.com/manaflow-ai/cmux/issues/847 is the tracker"))
      .toBe("https://github.com/manaflow-ai/cmux/issues/847 is the tracker");
  });

  test("links an explicit slug even with no session repository", () => {
    expect(html("see teamleaderleo/stensibly#12", null)).toBe(
      "see [teamleaderleo/stensibly#12](https://github.com/teamleaderleo/stensibly/issues/12)"
    );
  });

  test("leaves a bare reference as text when the repository is unknown", () => {
    expect(html("see #847", null)).toBe("see #847");
  });

  test("links a commit SHA", () => {
    expect(html("fixed by a360a95")).toBe(
      "fixed by [a360a95](https://github.com/manaflow-ai/cmux/commit/a360a95)"
    );
  });

  test("does not touch a line that has nothing to link", () => {
    const text = "nothing here, just prose about deadbeef and 12345678.";
    expect(html(text)).toBe(text);
  });
});
