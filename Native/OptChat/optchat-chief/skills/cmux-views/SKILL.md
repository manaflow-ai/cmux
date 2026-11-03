---
name: cmux-views
description: "Build a view the person asked for (a sidebar section or a Session Info section, such as a view of the PRs from the last 24h) as the cmux customize app, which shows up live with no restart or install."
cmux-managed: true
---

# Build a cmux view

Use this when the person asks for a view, panel or section of their own in
cmux: a list at the bottom of the sidebar, or a section in a chat's Session
Info. Write it yourself; do not send them to the App Store or a settings page.

## Write the customize app

The customize app is two files in `~/.config/cmux/customize`. cmux watches the
folder: every save reloads the view, and the first save installs the app with
the scopes its manifest asks for. Nobody restarts or clicks Install.

- `cmux-app.json`: manifest v1, id `local/customize`, `"main": "main.js"`, the
  `scopes` it needs (`net:api.github.com`, `actions:run` to open links;
  `integration:github:read` as an optional scope), and the sections:
  - `contributes.sidebarSections`: `{id, title, symbol, defaultRegion, render, maxRows}`.
    `defaultRegion: "bottom"` is the band under the workspace list.
  - `contributes.sessionInfoSections`: the same entry without `defaultRegion`;
    it shows in each chat's Session Info.
  - `activation`: `onSidebarSection:<id>` / `onSessionInfoSection:<id>` for each.
- `main.js`: a classic script (no `import` or `export`) using the scene globals
  (`VStack`, `Row`, `ForEach`, `EmptyState`, `signal`, `computed`, `cmux`). It
  ends with `globalThis.__cmuxAppExports = { renderA, renderB }`, one entry per
  `render` name. A render function gets the mount context as its argument; for
  a Session Info section that is `{ session_id, cwd, branch?, harness? }`.

For GitHub, call `cmux.integrations.github.request({method: "GET", path})`
first (the connected account, `@me` works) and fall back to `cmux.net.fetch`
on `https://api.github.com` with the `login` setting. Search has no OR across
`author:`, `review-requested:` and `assignee:`: run one search each and merge
by id. A branch's pull requests are `is:pr head:<branch>`; a script cannot read
the git remote from `cwd`. With no branch, render an `EmptyState` and make no
request.

The full copy-paste example for "a view of the PRs from the last 24h" (both
files, a sidebar section and a Session Info section) is in cmux's
`skills/cmux-customization/references/local-app-views.md`. Use it as written.
This recipe is the native scene view; it is not the web pane recipe.

## Where it shows

The first time cmux sees a section it adds it at the end of its
`defaultRegion`. If the person moved or removed it, that choice stays. To
restore it on purpose:

```sh
cmux apps place local/customize#recent --region bottom
```

## When it does not show

Read the app's log for script errors and refused scopes, fix the file, save:

```sh
cmux raw command --request-json '{"cmd":"apps-logs","app":"local/customize"}'
```

## Adding a view to an existing customize app

There is one customize app. Read both files first and keep everything in them:
add the new section entry and its activation next to the existing ones, add
the new render function, and add its name to the one existing
`__cmuxAppExports` object. A second `__cmuxAppExports` assignment replaces the
first and the earlier sections stop rendering.
