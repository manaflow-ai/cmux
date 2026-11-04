# Gallery window

A light native window for gallery stages: a real draggable, resizable macOS window
(AppKit and WebKit only, no CmuxNext package, no app build) that looks like your own
cmux. It is not the DEV app; it shows the gallery's real components in it.

    scripts/cmux-next/gallery-window.py --entry agent-pane.composer
    scripts/cmux-next/gallery-window.py --entry pages.diff --variant unified --sizes narrow,1000x700
    scripts/cmux-next/gallery-window.py --entry agent-pane.composer --gallery "$BRANCH_GALLERY_URL"

The launcher reads your appearance from `~/.config/cmux/cmux-next.json` (the file your
nightly or DEV build uses), and from Ghostty's config where cmux follows it:

- the theme (`appearance.appTheme`, else `appearance.theme`, else Ghostty's `theme`, on
  the side the system shows for a `light:A,dark:B` pair), accent, density, `app.uiScale`
  and `appearance.interfaceScale`;
- the backdrop (`appearance.background`): a painting (Shuffle Daily picks today's work
  from the app's own rotation), a `file:` or `system:` picture, or `desktop`. A
  translucent or glass window with no picture shows the desktop through a behind-window
  material. The host draws it behind a clear web view, and the page paints the theme
  tint over it (`backdrop=host`, at your Opacity or the theme's wallpaper tint), as
  `WindowBackdrop` layers the app's window.

It opens one window per size (`--sizes`, default narrow, normal and wide: the gallery's
420, 760 and 1200 pane widths), side by side. Each window replays the variant's play
steps on a loop (`--loop SECONDS`, 0 shows it once). Cmd-R reloads every window,
Cmd-W closes one, Cmd-Q quits. Edits show through the gallery's HMR as usual.

The stages come from the local HMR gallery (`scripts/cmux-next/preview.sh gallery`,
started or reused) or any gallery URL given with `--gallery`. `--print-spec` prints what
the host would open, on any OS. The host builds with `swift build -c release` on first
run, in seconds.
