# cmux NEXT view shell

The UI of cmux NEXT in real, draggable, resizable macOS windows, without the app: no terminals,
Ghostty, daemons, Cloud or Chief. Leo, 2026-11-04: "a dragabble window that is legit the app
through and through without the heavy bits".

Each window is an `NSWindow` with the system titlebar, traffic lights and vibrancy. Its content is
the webviews mock app (`webviews/src/gallery/mock-app.html`, see `webviews/src/gallery/ENTRIES.md`, "The
mock app") with `chrome=native`: the sidebar, tab strips and every pane's real web surface (agent
pane, transcript, composer, menus, Session Info, New Tab, Home) on the in-page mock host. The
shell is one Swift file and links nothing of the app, so it builds in seconds and only when this
folder changes. Everything else (the fixture, scripts, density, theme, CPU contention, extension
slots) is a URL key the web side reads, so changing it never needs a native build.

```sh
Prototypes/ViewShell/launch.sh --size 1512x982 --size 1280x800 --size 900x700 --script streaming
cmux preview open --fixture app.window/new-tab --density compact     # the same, through the CLI
```

- **Hot reload.** With no `--url`/`--dist`, the launcher uses the gallery dev server on
  `127.0.0.1:4210` (`bun run gallery:dev`) and starts it when none answers. Vite's hot reload and
  the gallery's per-entry reload (`dev-server/galleryLive.ts`) update every open window when a web
  file is saved, with no restart.
- **Built bundle.** `--dist webviews/dist/gallery` serves a built gallery (`bun run gallery:build`)
  from the shell itself; nothing listens on a port.
- **Your look.** The shell reads `appearance.theme` (a light/dark pair takes the system's side) and
  `appearance.accent` from `~/.config/cmux/cmux-next.json` (or `CMUX_NEXT_CONFIG_FILE`); a flag on
  the command line wins.
- **Several sizes.** One window per `--size WxH`; each plays its `--script` on a loop.
- **Captures.** `--capture DIR` saves `DIR/<W>x<H>.png` per window once its panes are ready
  (`--quit` exits after the last, or with 1 when a window is not ready within `--ready-timeout`
  seconds), and every window prints `ready_ms=` (load to ready). A capture is the web content
  only: where the window shows the system glass, the PNG is transparent.
- **Any axis.** `--KEY VALUE` passes a mock app key: `--fixture`, `--fixture2`, `--layout`,
  `--density`, `--scale`, `--theme`, `--colorScheme`, `--script`, `--cpu`, `--slot`, and the rest
  in `webviews/src/gallery/mock-app/axes.ts`.

How it differs from the gallery: the gallery shows one entry's states, each alone in a frame; the
shell shows the whole app, one window per state, at real sizes, in real windows.

Not yet: the person's background picture (`appearance.background`) behind the glass, and the
read-only attach to the person's real acpmux (the mock host is the only model today).

## Live code

A Debug shell takes new Swift code for its own views while it runs: no relaunch.

```sh
swift build --package-path Prototypes/ViewShell        # Debug: linked -interposable
"$(swift build --package-path Prototypes/ViewShell --show-bin-path)/cmux-view-shell" --live ~/.cache/cmux-view-shell/live &
# edit Sources/ViewShell/Badge.swift, then:
Prototypes/ViewShell/inject.sh --live ~/.cache/cmux-view-shell/live Sources/ViewShell/Badge.swift
```

`inject.sh` compiles the module with the Debug build's settings, links only the edited files into a
signed dylib and moves it into the live folder. It also links, unnamed, every file the running
Debug build never compiled (a new file) and every file changed since that build (it prints
`also X.swift` for each), so each patch holds all of the new code: a new view in a new file,
used from an edited one, applies, and patching again never leaves an earlier patch's copy behind. The shell (`LiveCode.swift`) loads it, interposes
every Swift function the patch defines onto the executable's own (and onto an earlier patch's
copy, so the same file can be patched again and again), and redraws. The patch can be compiled on another Mac at the same commit and copied
into the folder; it is the same file.

What applies live: any change inside a function or computed property, a view's body included,
and new files with new types and functions. A
view whose `body` is `AnyView(content)` (`PreviewBadge`) may also change what it builds, its
modifiers and their types. What needs a rebuild: a new or changed stored property, a changed
function signature, a new type, conformance or enum case in an existing file, `main.swift` and `LiveCode.swift`
themselves, resources and the package manifest. A patch whose internal or public
types change size (a stored property added or removed, or retyped to another size) is refused before anything
is repointed: the shell compares each type's size and stride, or a class's instance size, with
this build's and prints `refused: stored properties changed`. A reorder, a same-size retype or a
change to a `private` type (its symbols are local, so the check does not see it) still needs a
rebuild (`scripts/cmux-next/try-pr.sh` classifies a PR's diff and says so). `--live-render DIR` draws the badge offscreen
after each patch (`generation-N.png`), and `--headless` runs the loop with no windows, so a host
without a screen can measure it (`scripts/measure/live-code-shell.sh`).
