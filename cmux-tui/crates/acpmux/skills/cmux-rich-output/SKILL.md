---
name: cmux-rich-output
description: "Show work in a cmux chat as more than text when it helps: diagrams, charts and math the chat draws, live HTML pages, a page or file opened beside the chat, slide decks with present mode and PDF or PowerPoint export, documents as PDF, and LaTeX. Load it when the person asks for a chart, diagram, deck, slides, presentation, report, PDF or document, or when a picture would explain better than prose."
---

# Rich output in a cmux chat

cmux is a browser at heart: the chat and every pane beside it run on the Chromium the app
already ships. Everything here is optional. Use it when it explains better than prose, and
never because it exists. The person's own instructions win.

## Pick the lightest form

1. Prose, a list or a Markdown table.
2. A fence the chat draws. Other clients show its source, so it is always safe to write:
   - ```` ```mermaid ````: flowcharts, sequence, state, class, ER and Gantt diagrams.
   - ```` ```vega-lite ```` (a JSON spec): bar, line, area, point, pie (`arc`) and other charts.
     Put the rows in `data.values`; the chat fetches nothing, so a `data.url` draws nothing.
     The chat applies its own light or dark theme: leave colors and backgrounds out.
   - ```` ```chart ````: the same charts from small JSON, no Vega-Lite needed:
     `{"type": "bar", "data": [{"k": "a", "v": 3}], "x": "k", "y": "v"}`. type is bar, line, area,
     pie or scatter; y may be a list (a series each); `labels` plus `series: [{name, values}]` works too.
   - Perf and benchmark numbers (before and after, p50 and p95, memory over time): give the numbers
     as text or a table first, then the same numbers as a ```` ```chart ```` beside them, never instead
     of them, so the reply still reads where charts do not draw. A bench before and after:
     `{"type": "bar", "title": "Cold start (ms)", "data": [{"run": "p50", "before": 910, "after": 590}, {"run": "p95", "before": 1240, "after": 760}], "x": "run", "y": ["before", "after"]}`.
     Memory or time over a run is a `line` with the time or step as x.
   - Math: `$e^{i\pi} + 1 = 0$` inline, `$$ ... $$` on its own lines (KaTeX).
   - ```` ```html ```` or ```` ```svg ````: a static picture in the chat; scripts wait for the
     person's Run.
3. A live page in the chat: the `render` tool (cmux MCP server) with one self-contained HTML page,
   for a chart the person can hover, a small calculator, a three.js scene.
4. A file beside the chat: a page, deck or document the person keeps, reopens or sends on.

## Open a page or file beside the chat

- `open` (cmux MCP server): `{kind: "page", url}` or `{kind: "file", path}`. It opens in the column
  right of this chat by default. From a shell: `cmux browser open URL`, `cmux file open PATH`.
- An `.html` file opens as a real Chromium page: its relative CSS, images and scripts load. A PDF
  opens in Chromium's PDF viewer. A Markdown file opens in cmux's Markdown page.
- A browser tab does not reload a file when it changes. For a page you will iterate on, serve the
  folder with a dev server that reloads (`bunx vite`, `npx live-server`) from a background shell:
  the chat shows its `localhost` address as a chip that opens beside the chat, and saves reload it.

## Slide decks

A deck is one HTML file, one `<section>` per slide. Copy `templates/deck.html` (beside this file)
into the project (for example `slides/<topic>.html`), then change only the slides between
`<main class="deck">` and `</main>`, the `<title>`, and if needed a `--cmux-*` or `--deck-*` value
at the top of the `<style>`. Keep the `<script>` last and unchanged: it draws the slide strip, the
arrow keys, Present (F, Esc exits), Export PDF and Export .pptx.

- A slide is 1280 x 720 pixels. One idea per slide, about 40 words at most, text 24px or larger.
- `<section class="title">` for a title slide, `class="center"` for a quote or one number,
  `<div class="cols">` for two columns, `<aside class="notes">` for speaker notes.
- Pictures: inline `<svg>` (draw a chart's bars yourself; `currentColor` follows the theme), or an
  image file beside the deck. Export .pptx carries inline SVG and `data:` images; it leaves out an
  image file the browser will not read, and says so.
- Open it with `open {kind: "file", path}` and tell the person they can present or export it.
- A PDF yourself, with the browser REPL (`browser_repl_eval`):
  `await page.goto("file:///abs/slides/topic.html"); await page.pdf({path: "/abs/slides/topic.pdf", preferCSSPageSize: true, printBackground: true})`.
  One slide per page, in the light theme.
- Export .pptx is the person's click: it loads a PowerPoint writer (pptxgenjs, about 157 KB) from
  cdn.jsdelivr.net the first time and saves an editable deck: text stays text.

## Documents and PDF

- A report or handout the person will print or send: one HTML file with print CSS
  (`@page { size: letter; margin: 0.75in }`), opened beside the chat. Its PDF is the person's
  File > Print > Save as PDF, or `page.pdf({path, printBackground: true})` from the browser REPL.
- Markdown is fine for reading in cmux; write HTML when the person wants a PDF.
- cmux has no Word writer. When the person needs .docx and `pandoc` is installed:
  `pandoc doc.md -o doc.docx`.

## LaTeX

- Math in the chat is KaTeX: use `$...$` and `$$...$$`, no preamble.
- A full LaTeX document needs TeX, which cmux does not bundle. When `tectonic`, `latexmk` or
  `pdflatex` is on PATH (a Cloud VM, a Mac with MacTeX), compile it and open the PDF with
  `open {kind: "file", path}`. Otherwise say so; never install a TeX distribution (hundreds of
  MB) unless the person asks.

## Rules

- Make a deck, document or page only when the person asks or agrees; offer it in one line otherwise.
- Write files in the project or where the person says, never only in a temp folder, and give the path.
- Pages load scripts only inline or from cdn.jsdelivr.net, unpkg.com or cdnjs.cloudflare.com, with
  an exact version.
