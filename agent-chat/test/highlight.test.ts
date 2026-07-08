import { highlightCode } from "../src/ChatMarkdown";
import { DEFAULT_ANSI_PALETTE, resolveGhosttyTheme } from "../theme";

const html = await highlightCode("const answer: number = 42;\nconsole.log(answer);\n", "ts");
if (!html.includes("<span") || !html.includes("style=")) {
  throw new Error(`expected token spans with styles, got: ${html}`);
}
if (!html.includes("answer") || !html.includes("console")) {
  throw new Error(`highlight output lost code text: ${html}`);
}
if (/onig|wasm/i.test(html)) {
  throw new Error(`highlight output unexpectedly referenced wasm/onig: ${html}`);
}

const css = await Bun.file(new URL("../public/app.css", import.meta.url)).text();
for (const needle of [
  "--ansi-bright-blue",
  "--ansi-green",
  "--shiki-token-keyword: var(--ansi-bright-blue)",
  "--shiki-token-string: var(--ansi-green)",
  "--shiki-token-function: var(--ansi-blue)",
  "--font-size-code",
]) {
  if (!css.includes(needle)) throw new Error(`expected palette/font-driven CSS variable mapping: ${needle}`);
}

const theme = resolveGhosttyTheme();
if (theme.palette.length !== 16 || theme.palette.some((c) => !/^#[0-9a-f]{6}$/i.test(c))) {
  throw new Error(`resolved theme must expose 16 ANSI colors, got: ${JSON.stringify(theme.palette)}`);
}
if (DEFAULT_ANSI_PALETTE.length !== 16) throw new Error("default ANSI palette must contain 16 colors");

console.log("highlight assertions passed");

export {};
