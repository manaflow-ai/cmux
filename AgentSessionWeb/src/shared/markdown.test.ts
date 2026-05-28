import { expect, test } from "bun:test";
import { escapeMarkdownRawHTML, renderPlainTextHTML } from "./markdown";

test("markdown raw HTML is escaped before parsing", () => {
  expect(escapeMarkdownRawHTML("<script>alert(1)</script> & text")).toBe(
    "&lt;script>alert(1)&lt;/script> &amp; text",
  );
});

test("plain text fallback preserves line breaks safely", () => {
  expect(renderPlainTextHTML("hello\n<script>x</script>")).toBe("hello<br>&lt;script&gt;x&lt;/script&gt;");
});
