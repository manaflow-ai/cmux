# `cmux browser repl`

Run JavaScript in a persistent JavaScriptCore session that drives the browser
panes of your cmux workspace. The API is Playwright: `page`, locators,
`keyboard`, `mouse`, events and waits behave as in Playwright. Input is native:
pages see trusted events.

## Usage

    cmux browser repl 'await page.goto("https://example.com"); snapshot()'
    cmux browser repl --eval - < script.js
    cmux browser repl --session work 'const s1 = await snapshot()'
    cmux browser repl list | reset <session> [--all-workspaces] | guide

Without `--session` each call is one-shot: its tabs close at the end unless
`page.keep()` was called. With `--session NAME`, top-level `const`/`let`
bindings and tabs persist until `reset NAME` or 30 minutes idle. A session
binds to your cmux workspace; the same name in another workspace is another
session. Outside cmux, one session per name is shared by every caller
outside cmux, whatever workspace is focused (its tabs open in the one
focused when it was made). `list` and `reset` act on your sessions
(`--all-workspaces` for every one). A name
is up to 64 letters, digits, `.`, `_` and `-`; at most 32 sessions are open
at once.

- The last expression's value prints (a promise is awaited first);
  `undefined` prints nothing. `console.log()` prints too.
- 120 second timeout per call (`--timeout <ms>`).
- A call prints at most 25,000 characters (`--max-output <chars>`, `0` for
  no limit). Past that, its whole output goes to a file: the start, the
  last lines and the file's path print. Read the file with `fs` or your
  own tools.
- `page` is ready at once: the first use opens a tab. Nothing you do takes
  the user's focus: `tabs.open()`, input, dialogs and waking a tab never
  change the user's window, workspace, pane, tab or keyboard focus, also when
  the user works in the same workspace. Only `page.bringToFront()` shows a
  tab, and a `sites.browserAuth` sign-in sheet asks the user to type.

## Globals

- `page`: the current tab, a Playwright `Page` with a stable `page.id`.
- `tabs`: `list()`, `open(url, { background })`, `current()`, `use(tabOrId)`,
  `get(id)`. `list()` returns `{ id, title, url, active, current, state }`
  for every tab in the workspace without attaching or waking it; `list({ all: true })` adds the
  user's tabs in other workspaces and windows (with `workspace`), and
  `use(id)` takes any of them; `use(id)` and `get(id)` return a `Page`.
  `content({ urls, format })` loads URLs in background tabs and returns
  `[{ url, title, status, content }]` (`format`: `text`, `markdown`,
  `html`, `snapshot`) without changing the current tab.
  `history({ query, from, to, limit })` returns cmux browser history,
  newest first, as `{ url, title, dateVisited }`.
- `snapshot(target?, options?)`: accessibility snapshot of `page`, a locator or
  a ref. Options: `interactive` (controls plus headings and landmarks),
  `viewport` (only what is on screen), `showHidden`, `maxChars` (print
  budget, below), `options` (one line per option), and `urls` (every
  link's `[url=…]`; links with no name show it anyway).
- `screenshot(target?, options?)`: an image of the viewport, `{ fullPage }`, a
  locator or a ref. `{ annotate: true }` draws each ref's box and label.
  Printing an image saves it to a file and prints the path.
- `fetch(url, init)`: standard fetch with the current tab's cookies
  (`credentials: "same-origin"` or `"omit"` to send fewer); bodies over
  64 MiB fail, download those in a tab.
- `fs`, `path`, `os`, `Buffer`: Node APIs. Files are limited to the directory
  you ran the command in and the system temp directory. `import("node:fs")`
  and `require("fs")` return the same modules.
- `sleep(ms)`, `display(value)`, `console`.
- `session`: `name(label)` labels this session's tabs; `keep(page)` keeps a
  tab after a one-shot run; `id`; `guide()` returns this text.
  `allowedDomains(["example.com", "*.example.org"], { lock })` (a wildcard
  over a public suffix, such as `*.com` or `*.co.uk`, is refused;
  `example.com` also allows `www.example.com`, `=example.com` only the
  exact host, as `sites.browserAuth` needs on such a host),
  `prohibitedDomains([...])` and `blockIPAddresses(true)` limit navigations,
  new tabs, `fetch` (every redirect), site tools and the subresources of
  tabs this session opened. A tab this session opened never loads a blocked page (the
  navigation is cancelled and the action fails); a tab you claimed stays
  where it is, but reads and input on it fail while it shows a blocked
  page. `blockedNavigations()` lists the blocks. The policy is enforced
  outside this JavaScript context, so `{ lock: true }` cannot be undone. `configure({ userAgent, extraHTTPHeaders, permissions, proxy })`
  sets browser-context options for the tabs this session opened (a tab you
  claimed keeps its own; `null` clears one; a proxy applies to tabs opened afterwards, in a private
  profile without your cookies). `storageState({ path })`
  and `setStorageState(stateOrPath)` save and restore cookies and
  localStorage (Playwright's format); a save covers the current tab's site
  only, `{ all: true }` the whole profile, `{ urls }` those URLs. `downloads()` lists downloads.
  `record()` returns a recorder; `stop()` writes `trace.jsonl`, a PNG per
  action and `run.png`, an animated PNG of the run.
- `secrets.set(name, value, { domains, totp })` or `secrets.load(file)`
  (`{ "<domain>": { name: value } }`) registers a secret; type it with
  `locator.fill(secret("name"))` or `locator.type(secret("name"))`. It is
  typed only into frames on its domains, in a tab this session opened,
  while `session.allowedDomains([...])` allows only its domains (and the
  policy cannot widen past them afterwards), and its value prints, reads and
  saves as `<secret:name>` everywhere. `{ totp: true }` types the current
  one-time code of a base32 seed.
- `search(query, { engine, limit })`: `[{ title, url, snippet }]` from
  DuckDuckGo (default), Bing or Google.
- `tools.register(name, fn, { description, params, domains })` adds a
  callable `tools.name(args)` to the session; `fn(args, { page, session,
  tabs })`; `params` like `{ q: "string", n: "number?" }` are checked.
- `page.exportContent()` writes the page as Markdown and returns the file's
  path; `{ format: "pdf" }` (or `md`, `docx`, `xlsx`, `csv`, `pptx`, ...)
  exports a Google Docs, Sheets or Slides tab; `{ transcript: true }` writes a
  YouTube watch page's captions as text.
- To drop files on a drop zone:
  `locator.dispatchEvent("drop", { dataTransfer: { files: [path or { name, mimeType, buffer }] } })`.

## Snapshot

    title: Sign up
    url: http://localhost:8765/
    - navigation "Main" [ref=e1]:
      - link "Home" [ref=e2]
    - main:
      - heading "Sign up" [level=1]
      - textbox "Email" [ref=e3] [placeholder="you@x.com"]: "me@x.com"
      - checkbox "Accept terms" [ref=e4] [checked]
      - combobox "Plan" [ref=e5] [options: Free, Pro, Team]: "Pro"
      - table "Scores":
        - row [header]: "Name | Score"
        - row:
          - cell: "Ada"
          - link "Profile" [ref=e6]
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
- Only what a user can see prints: collapsed, `display:none`,
  `content-visibility:hidden`, inert and `aria-hidden` content does not
  (`showHidden` adds it). Names come from content only for buttons, links,
  headings and similar leaves, so nothing prints twice. Tables print
  `row: "a | b"` when every cell is text; layout tables flatten.
- Frames (also cross-origin and nested) and shadow roots, closed ones too,
  are inlined; refs and locators work inside them.
- An open dialog or file chooser prints first, under the header.
- Printing a snapshot shows its diff against the previous snapshot of the
  same tab when that is shorter (for a large page, 30% shorter), else the
  full tree. `.tree` and `.diff` are always there. Diff lines start with `+`
  (added), `-` (removed) or `~` (changed, new version); unchanged ancestors
  are shown for context.
- A printed snapshot is at most 20,000 characters (`maxChars`). A larger
  page prints condensed: on-screen controls, the focused element and the
  headings and landmarks first, then the page from the top; long runs of
  similar items (list items, rows, cards) keep their first few. Each cut
  is one line, `- … 480 more listitem (480 refs): snapshot("e12")`, and a
  last `# condensed …` line says what is left out. Refs in the cut part
  work. For more: `snapshot("e12")` for that region,
  `snapshot({ viewport: true })` after scrolling, or
  `snapshot({ maxChars: Infinity })` and `.tree` for everything (search
  `.tree` in code rather than printing it).
- Refs stay valid until their element is removed, also when its name or
  state changes, so there is no need to take a new snapshot after every
  action; a stale ref fails at once and says so.

## Dialogs and file choosers

With a `page.on("dialog")` or `page.on("filechooser")` listener (including
`waitForEvent`), Playwright rules apply. Without one, in a tab you opened, the
dialog or chooser stays open and shows in the snapshot. While a JavaScript
dialog is open the page cannot run script, so page calls fail with a message
that says so. A tab you did not open (`tabs.use()` of the user's tab) is the
user's: its dialogs, file choosers, downloads and permission prompts go to
the user unless you have a listener for that event on the page, or your own
click, key, drag, navigation or `page.evaluate()` (within its first
second) opened the dialog or chooser, which then comes to you as in a tab you opened; a window your
action opens there comes to you as a `popup` and stays the user's tab. A dialog
that opens during Meta+C, Meta+X or Meta+V is dismissed at once, so it
cannot hold the clipboard command; listeners still get it, and the next
snapshot prints `dialog dismissed: ...` once.

    page.dialog()        // { type, message, defaultValue, accept(text?), dismiss() } or null
    page.fileChooser()   // { multiple, setFiles(paths), cancel() } or null

## Hibernated and crashed tabs

`state` in `tabs.list()` is `live`, `hibernated` (cmux unloaded the hidden
page to save memory), `waking` (it is loading again) or `crashed`. Any call
on a hibernated tab loads it again first, in the background, and waits up to
30 s; it fails with `hibernated` when the user stopped that load or it ended
without a page, and with a timeout when it is still loading (retry). A
crashed tab fails every call but navigation with `crashed`; call
`page.reload()` or `page.goto(url)`. Errors name the tab as
`tab <id> ("title", url)`.

## Page additions

- `page.consoleMessages({ level, filter, limit })`, `page.errors()`: console
  and uncaught-error history of the tab.
- `page.clipboard`: `readText()`, `writeText(text)`, `read()`, `write(items)`
  on the tab's own clipboard, which Meta+C, Meta+X and Meta+V use. Those
  shortcuts work only in tabs you opened; a page that keeps one running
  past 5 s crashes its tab (`page.reload()` brings it back). In tabs you
  opened, what the page's own scripts copy (a Copy button's
  `navigator.clipboard.writeText` or `execCommand("copy")` after your
  click) also lands here, never on the system clipboard, so
  `page.clipboard.readText()` returns it.
- `page.elementAt(x, y)`: `{ ref, role, name, box }` at a viewport point.
- `page.keep()`: keep this tab after a one-shot run.
- `page.markdown({ main, links, images, start, maxChars })`: the page as
  Markdown with iframes and shadow roots in place; `main: true` keeps the
  main content; a cut ends with where to continue.
- `page.extract({ $: ".item", name: "h3", url: "a@href", tags: ["li"] })`:
  structured data by selectors; `"sel@attr"` reads an attribute, `["sel"]`
  every match, `{ $: sel, ...fields }` one object per match.
- `page.searchText(pattern, { regex, caseSensitive, context, scope, limit })`:
  `{ total, matches: [{ match, context, ref }] }`.
- `page.scrollToText(text)` (returns the ref), `page.scroll({ pages, target })`
  (native wheel, negative pages scroll up), `page.scrollInfo(target?)`
  (`{ y, pagesAbove, pagesBelow, ... }`).
- `page.dropdownOptions(ref)`: options of a `<select>` or an open ARIA
  combobox, listbox or menu, with refs for ARIA options.
- `page.highlight(targets?)`, `page.hideHighlight()`, `locator.highlight()`:
  boxes and ref labels on the page.

## Tips

- Read with `snapshot({ interactive: true })` first, then `snapshot()`.
- Act with refs or Playwright locators; after an action, print `snapshot()`
  again to see what changed.
- Actions wait for the element as Playwright does. A stale ref fails fast.
- Downloads: `const d = page.waitForEvent("download"); await page.click(...);
  (await d).path()` gives a readable file.
