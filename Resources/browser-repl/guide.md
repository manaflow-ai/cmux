# `cmux browser repl`

Run JavaScript in a persistent JavaScriptCore session that drives the browser
panes of your cmux workspace. The API is Playwright: `page`, locators,
`keyboard`, `mouse`, events and waits behave as in Playwright. Input is native:
pages see trusted events.

## Usage

    cmux browser repl 'await page.goto("https://example.com"); snapshot()'
    cmux browser repl --eval - < script.js
    cmux browser repl --session work 'const s1 = await snapshot()'
    cmux browser repl list | reset <session> | guide

Without `--session` each call is one-shot: its tabs close at the end unless
`page.keep()` was called. With `--session NAME`, top-level `const`/`let`
bindings and tabs persist until `reset NAME` or 30 minutes idle. A session
binds to your cmux workspace, or to the focused workspace outside cmux.

- The last expression's value prints (a promise is awaited first);
  `undefined` prints nothing. `console.log()` prints too.
- 120 second timeout per call (`--timeout <ms>`).
- `page` is ready at once: the first use opens a tab. `tabs.open()` never
  steals focus.

## Globals

- `page`: the current tab, a Playwright `Page` with a stable `page.id`.
- `tabs`: `list()`, `open(url, { background })`, `current()`, `use(tabOrId)`,
  `get(id)`. `list()` shows every tab in the workspace; `use(id)` attaches one.
- `snapshot(target?, options?)`: accessibility snapshot of `page`, a locator or
  a ref. Options: `interactive`, `showHidden`, `maxChars`, `options`.
- `screenshot(target?, options?)`: an image of the viewport, `{ fullPage }`, a
  locator or a ref. `{ annotate: true }` draws each ref's box and label.
  Printing an image saves it to a file and prints the path.
- `fetch(url, init)`: standard fetch with the current tab's cookies.
- `fs`, `path`, `os`, `Buffer`: Node APIs. Files are limited to the directory
  you ran the command in and the system temp directory. `import("node:fs")`
  and `require("fs")` return the same modules.
- `sleep(ms)`, `display(value)`, `console`.
- `session`: `name(label)` labels this session's tabs; `keep(page)` keeps a
  tab after a one-shot run; `id`; `guide()` returns this text.

## Snapshot

    title: Sign up
    url: http://localhost:8765/
    - navigation "Main" [ref=e1]:
      - link "Home" [ref=e2] [url=/aria.html]
    - main:
      - heading "Sign up" [level=1]
      - textbox "Email" [ref=e3] [placeholder="you@x.com"]: "me@x.com"
      - checkbox "Accept terms" [ref=e4] [checked]
      - combobox "Plan" [ref=e5]: "Pro"
      - table "Scores":
        - row: "Name | Score"
      - iframe "Payment" [ref=e7]:
        - textbox "Card" [ref=f1e1]

- Refs (`e5`, `f1e2` inside a frame) work anywhere a selector works:
  `page.locator("e5").click()`, `page.ref("e5")`, `snapshot("e5")`,
  `screenshot("e5")`. A ref names one element for its life and is never
  reused. A removed element's ref fails at once with `ref e5 is stale`; take
  a new snapshot then.
- Refs mark controls, iframes, scrollable regions and named landmarks,
  dialogs and lists. States: `[checked]`, `[checked=mixed]`, `[disabled]`,
  `[expanded]`, `[expanded=false]`, `[pressed]`, `[selected]`, `[focused]`,
  `[required]`, `[invalid]`, `[readonly]`, `[level=N]`, `[scrollable]`.
- Frames (also cross-origin) and open shadow roots are inlined.
- An open dialog or file chooser prints first, under the header.
- Printing a snapshot shows its diff against the previous snapshot of the
  same tab when that is at least 30% shorter, else the full tree. `.tree` and
  `.diff` are always there. Diff lines start with `+` (added) or `-`
  (removed); unchanged ancestors are shown for context.

## Dialogs and file choosers

With a `page.on("dialog")` or `page.on("filechooser")` listener (including
`waitForEvent`), Playwright rules apply. Without one, the dialog or chooser
stays open and shows in the snapshot. While a JavaScript dialog is open the
page cannot run script, so page calls fail with a message that says so.

    page.dialog()        // { type, message, defaultValue, accept(text?), dismiss() } or null
    page.fileChooser()   // { multiple, setFiles(paths), cancel() } or null

## Page additions

- `page.consoleMessages({ level, filter, limit })`, `page.errors()`: console
  and uncaught-error history of the tab.
- `page.clipboard`: `readText()`, `writeText(text)`, `read()`, `write(items)`
  on the tab's own clipboard, which Meta+C, Meta+X and Meta+V use.
- `page.elementAt(x, y)`: `{ ref, role, name, box }` at a viewport point.
- `page.keep()`: keep this tab after a one-shot run.

## Tips

- Read with `snapshot({ interactive: true })` first, then `snapshot()`.
- Act with refs or Playwright locators; after an action, print `snapshot()`
  again to see what changed.
- Actions wait for the element as Playwright does. A stale ref fails fast.
- Downloads: `const d = page.waitForEvent("download"); await page.click(...);
  (await d).path()` gives a readable file.
