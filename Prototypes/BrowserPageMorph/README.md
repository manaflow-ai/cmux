# Browser page morph (prototype)

Leo, 2026-11-22: "i wonder if there are ways to morph between nearby web pages to reduce jarringness of things. e.g. light to dark and dark to light and colours and whatnot. you guys should test out lots of things and investigate what we can do. let's go deep. arbitrary tabs and jumps. we want everything to feel smooth as posisble while staying as fast as possible"

This prototype is a standalone page. It is not wired into the app and changes no default.

`index.html` runs ten live tabs (iframes) in one pane. The tabs mix light and dark pages and same-site and cross-site jumps. Each variant draws only an overlay. The incoming page is on screen in the first frame, and any pointer, wheel or key input removes the overlay.

| variant | what it does |
|---|---|
| `none` | A hard cut, as today. |
| `crossfade` | The outgoing page fades out over the new one in 120 ms. In the CEF host the outgoing page would be a snapshot layer. |
| `veil` | When the lightness jump is larger than 0.2 L\*, a flat wash of the outgoing page's background colour covers the new page. It starts at an opacity of 0.75 x the lightness change (at most 0.7) and fades over 150 ms. It needs no snapshot. |
| `chrome` | The tab strip and URL bar blend from the old page's theme colour to the new one's over 180 ms. The page cuts at once. |
| `veil+chrome` | The veil and the chrome blend together. |
| `slide` | The outgoing page slides 30% sideways while it fades, over 140 ms. Use it for back/forward. |

`vt/page.html` tests cross-document View Transitions in real Chromium. The bench injects `@view-transition { navigation: auto }` at document start, as `CEFDocumentScripts` would.

## Run

- Open the prototype: `python3 -m http.server -d Prototypes/BrowserPageMorph 8000`, then go to `http://localhost:8000/?variant=veil+chrome`.
- Keys in the prototype: `0`-`9` switch tabs, `[` and `]` go back and forward, `v` cycles the variant.
- Run the bench on a Mac test host, not an agent host: `npm i playwright-core && node bench.mjs --chromium <Chrome for Testing binary> --out out`.
- Summarize the bench: `node summarize.mjs out/results.json`.

The bench measures every switch with rAF:

- the handler's main-thread cost;
- the first frame that shows the new page;
- when the new content is 50%, 90% and 100% unobscured, computed from the overlay's animated opacity;
- frames missed against the display's measured frame interval;
- whether a wheel event 30 ms into a switch clears the overlay.

The findings are in cmuxterm-hq `docs/findings/browser-page-morph-2026-11-22.md`.
