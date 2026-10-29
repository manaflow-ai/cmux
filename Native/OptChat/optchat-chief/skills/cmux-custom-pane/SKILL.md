---
name: cmux-custom-pane
description: Build the user a custom pane in cmux, a small web app of their own (a dashboard, board, tracker or panel) that reads and drives cmux through cmux.call, opened beside the chat with hot reload; also edit one or submit it to the cmux App Store for review. Use when the user asks for a pane, panel, widget, dashboard or app inside cmux.
cmux-managed: true
---

# Build a custom pane

A custom pane is a local app: a folder with a manifest and a `web/` page.
cmux shows the page in a sandboxed web view; the page's only way out is
`cmux.call(op, params)`, which the app supervisor decides under the app's
grant. Saving a file reloads the open pane, so build it in small steps and
let the user watch.

## 1. Make the folder

```sh
LOCAL=$(cmux --json raw command --request-json '{"cmd":"apps-list"}' | jq -r .local_dir)
NAME=standup-board   # lowercase letters, digits and dashes, starts with a letter
test -n "$LOCAL" && test "$LOCAL" != null || exit 1
mkdir -p "$LOCAL/$NAME/web"
```

The app's id is `local/$NAME`. Write `"$LOCAL/$NAME/cmux-app.v2.json"`:

```json
{
  "manifestVersion": 2,
  "id": "local/standup-board",
  "name": "Standup Board",
  "version": "0.1.0",
  "description": "One line on what it shows.",
  "engines": { "cmux": "^2.0" },
  "runtime": { "web": { "root": "web/" } },
  "implements": { "cmux.pane/1": { "web": "web/index.html", "title": "Standup Board" } },
  "scopes": { "workspace:read": "List your workspaces." },
  "optionalScopes": {},
  "files": ["web/"]
}
```

Then `web/index.html`, `web/app.js` and `web/style.css`. The sample
`samples/apps/workspace-board` in the cmux repository is a complete one.

## 2. The page's rules

- Scripts load from files only: `<script src="app.js">`. Inline `<script>`,
  `eval`, frames, forms that post and other origins are blocked.
- No network: no CDN, no `fetch` to the internet. Copy a library into `web/`
  if you need one. Styles may be inline.
- Read and act through `await cmux.call(op, params)`. It resolves to the
  answer (`{value}` for a read) or throws an `Error` with `error.code`:
  `scope.missing` (not granted), `operation.unsupported`, `gesture.required`
  (ops that move focus never run from a pane).
- No event stream reaches a pane yet: read again on a timer (every few
  seconds) or on a button.
- Every scope the page uses goes in the manifest with a reason the user
  reads. Reads in `scopes`; anything that changes something in
  `optionalScopes`, and tell the user to allow it.

| Op | Scope | Answer |
| --- | --- | --- |
| `workspace.list` | `workspace:read` | `{value: [{id, name, focused, ...}]}` |
| `terminal.list` `{workspace}` | `terminal:read` | `{value: [{id, title, cwd, ...}]}` |
| `terminal.screen.read` `{workspace, terminal}` | `terminal:read` | the visible screen |
| `terminal.input.write` `{workspace, terminal, text}` | `terminal:execute` | sends the text |
| `agent.list` | `agent:read` | the agents and their states |
| `feed.list` | `feed:read` | the feed |
| `app.storage.get` / `app.storage.set` `{key, value}` | `storage:local` | the app's own data |

`console.log`, `console.error` and uncaught errors go to the app's log.
Read it to debug:

```sh
cmux raw command --request-json '{"cmd":"apps-logs","app":"local/standup-board"}'
```

## 3. Install and open it

An agent cannot install an app. Open its listing and hand the user one line,
"Click Install for Standup Board; it asks to read your workspaces":

```sh
cmux app store --app local/standup-board
```

Once it shows as installed, open it beside the chat and keep building; each
save reloads it:

```sh
cmux app open local/standup-board
```

A local app starts sandboxed with only its read scopes. When the page needs
an optional scope, the user allows it in the App Store, under Installed.

## 4. Submit it to the App Store

Only when the user asks to share it. They need a cmux Cloud sign-in and a
publisher name equal to their GitHub account or organization. Add
`"repository": "https://github.com/<publisher>/<repo>"` to the manifest, then
tell them: App Store, Installed, the app, Submit for Review. A reviewer
approves or rejects it; once approved, anyone can get it from the store's
Community section, and each new version goes through review again (raise
`version` first).
