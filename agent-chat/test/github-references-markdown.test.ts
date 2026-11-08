import { describe, expect, test } from "bun:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import ReactMarkdown from "react-markdown";
import remarkBreaks from "remark-breaks";
import remarkGfm from "remark-gfm";
import { remarkGitHubReferences } from "../src/githubReferences";

const slug = "manaflow-ai/cmux";
const issue847 = "https://github.com/manaflow-ai/cmux/issues/847";

/// Renders markdown through the transcript's own plugin list.
///
/// The interesting cases are all about which characters the parser decides are
/// content rather than prose, so the test asks the parser instead of asserting
/// on a rewritten string.
function render(markdown: string, repositorySlug: string | null = slug, streaming = false): string {
  return renderToStaticMarkup(
    React.createElement(ReactMarkdown, {
      remarkPlugins: [remarkGfm, [remarkGitHubReferences, { repositorySlug, streaming }], remarkBreaks],
      children: markdown,
    }),
  );
}

describe("references in prose", () => {
  test("a bare issue reference becomes a link", () => {
    expect(render("landed in #847 today")).toBe(`<p>landed in <a href="${issue847}">#847</a> today</p>`);
  });

  test("wrapping punctuation stays outside the link", () => {
    expect(render("landed in (#847).")).toBe(`<p>landed in (<a href="${issue847}">#847</a>).</p>`);
  });

  test("a reference naming its own repository ignores the session repository", () => {
    expect(render("see other/repo#12", null)).toBe('<p>see <a href="https://github.com/other/repo/issues/12">other/repo#12</a></p>');
  });

  test("a bare reference stays text when the session has no repository", () => {
    expect(render("see #847", null)).toBe("<p>see #847</p>");
  });

  test("an abbreviated commit SHA becomes a commit link", () => {
    expect(render("fixed by a360a95")).toBe('<p>fixed by <a href="https://github.com/manaflow-ai/cmux/commit/a360a95">a360a95</a></p>');
  });

  test("a line with no reference is left alone", () => {
    expect(render("nothing to link here")).toBe("<p>nothing to link here</p>");
  });
});

describe("references the parser says are content", () => {
  // Each of these is a place where the characters are what the author asked to
  // see. A rewriter that searches the markdown source has to re-derive the
  // fence, span and escape rules to find them, and writing `[#847](...)` into
  // any of them puts a URL on screen inside the reader's code.
  test("a code span is left alone", () => {
    expect(render("run `#847` please")).toBe("<p>run <code>#847</code> please</p>");
  });

  test("a double-backtick code span is left alone", () => {
    expect(render("run ``#847`` please")).toBe("<p>run <code>#847</code> please</p>");
  });

  test("a code span that wraps a line is left alone", () => {
    expect(render("a `#847\n#848` b")).toBe("<p>a <code>#847 #848</code> b</p>");
  });

  test("a backtick fenced block is left alone", () => {
    expect(render("```\n#847 inside\n```")).toBe("<pre><code>#847 inside\n</code></pre>");
  });

  test("a tilde fenced block is left alone", () => {
    expect(render("~~~\n#847 inside\n~~~")).toBe("<pre><code>#847 inside\n</code></pre>");
  });

  test("an indented code block is left alone", () => {
    expect(render("para\n\n    see #847 here\n\nafter")).toBe("<p>para</p>\n<pre><code>see #847 here\n</code></pre>\n<p>after</p>");
  });

  test("an existing link is left alone", () => {
    expect(render("[#847](https://example.com/a)")).toBe('<p><a href="https://example.com/a">#847</a></p>');
  });

  test("a bare URL is left to the autolinker", () => {
    expect(render("https://example.com/page#847")).toBe('<p><a href="https://example.com/page#847">https://example.com/page#847</a></p>');
  });

  test("a link reference definition keeps working", () => {
    expect(render("[#847]: https://example.com/a\n\nsee [#847]")).toBe('<p>see <a href="https://example.com/a">#847</a></p>');
  });

  test("a stray fence marker in prose does not disable the rest of the message", () => {
    // The parser reads this as ordinary text, so the references after it are
    // still prose. A source-level scan reads it as an unterminated fence and
    // silently stops linking anything that follows.
    expect(render("wrap it in ``` fences. also #847")).toContain(`<a href="${issue847}">#847</a>`);
  });
});

describe("references in block structures", () => {
  test("a heading is linked", () => {
    expect(render("# fix #847")).toBe(`<h1>fix <a href="${issue847}">#847</a></h1>`);
  });

  test("a blockquote is linked", () => {
    expect(render("> fix #847")).toBe(`<blockquote>\n<p>fix <a href="${issue847}">#847</a></p>\n</blockquote>`);
  });

  test("a table cell is linked", () => {
    expect(render("| a |\n| - |\n| #847 |")).toContain(`<a href="${issue847}">#847</a>`);
  });

  test("a list item is linked", () => {
    expect(render("- fix #847")).toContain(`<a href="${issue847}">#847</a>`);
  });
});

describe("while a message is still arriving", () => {
  // A number that is still being typed is a prefix of the number the agent
  // means: `#8471` passes through `#847` on the way in, and that prefix is a
  // link to a different issue that a reader can click during a pause.
  test("the token at the end of the message is held back", () => {
    expect(render("fix #847", slug, true)).toBe("<p>fix #847</p>");
  });

  test("a token with something after it is linked", () => {
    expect(render("fix #847 now", slug, true)).toBe(`<p>fix <a href="${issue847}">#847</a> now</p>`);
  });

  test("a trailing space is enough to settle the token", () => {
    expect(render("fix #847 ", slug, true)).toBe(`<p>fix <a href="${issue847}">#847</a></p>`);
  });

  test("a finished message links its last token", () => {
    expect(render("fix #847", slug, false)).toBe(`<p>fix <a href="${issue847}">#847</a></p>`);
  });

  test("an earlier reference is still linked while a later one is held", () => {
    expect(render("fix #847 and #84", slug, true)).toBe(`<p>fix <a href="${issue847}">#847</a> and #84</p>`);
  });
});
