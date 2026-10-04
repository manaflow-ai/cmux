# CmuxMessagesLab

The cmux-next Mac Home transcript is MessagesLab's own code
(`~/fun/messageslab`, variant appkit-native), not a rewrite: its rows,
springs and timing curves (`springs.json`), send morph, Liquid Glass field
and render-server field animation, blurred header and native scrolling.

## Layout

- `Sources/MessagesLabHome/Vendor/`: MessagesLab files, byte-identical to the
  pinned commit except the blocker patches. `vendor.tsv` lists each upstream
  path and the pin (first line).
  - catalyst core: Model, Engine (types and the reducer, kept as a projection
    of HomeStore), Layout, Transcript, Recycler, RowDrawing, Springs, Morph,
    Shapes, Fixture, Header, WindowView, Replay; `Resources/springs.json`.
  - appkit-port shim: UIKitNames, RoundedRect, LayerViews.
  - appkit-native: Compose, Materials, NativeScroll, HeaderBar,
    HeaderBackdrop, TranscriptAccess, SwipeReply (installed only when the
    owner can take a reply: `ChatIntents.canReply`, false until HomeOp has one).
  - Not vendored (MessagesLab test drivers or app shell): App, Host, Bench,
    SelfTest, FlashCheck, AttachCheck, ResolutionAudit, LiveRecord,
    tools/diff-harness, PagedSource, Pager.
- `Patches/`: one unified diff per edited vendored file. Every edit is also
  marked `cmux:` in the source.
- `Sources/MessagesLabHome/Cmux/`: cmux code in the same module (the upstream
  files have no access modifiers): `PaneHost` (the pane host and controller,
  derived from Host.swift, keeping its type names and layer order),
  `HomeProjection`/`ProjectionCore`/`HomeDiff`/`HomeMapping` (HomeStore
  snapshots to MessagesLab actions; sends and tapbacks to HomeIntents),
  `PaneHeaderView` (HeaderBar's avatar and pill inside the pane),
  `FixtureTheme` (cmux theme to Fixture colours), `MessagesLabHomeView`
  (the public view).

## Blocker patches

| file | why |
| --- | --- |
| Springs, Layout, TranscriptAccess, Model (fixture root) | resources live in the package bundle, not the app's main bundle |
| Model, Layout | live dates in the user's zone and locale (fixtures keep -07:00 and en_US) |
| WindowView, Compose | rows and field lines follow the view's own width (several Home tabs), not the process-wide `Metrics.current` |
| Fixture, Transcript, Morph | optional cmux theme; nil keeps MessagesLab's measured palette |
| HeaderBackdrop | the tint uses the theme background (MessagesLab's grey read as a band on a cmux pane) |
| Layout, Localizable.xcstrings | the placeholder says Message, not iMessage |
| Layout | a failed send that reached the owner unanswered says May Not Have Been Delivered (`CmuxStrings`, Resources/CmuxHome.xcstrings in every app language) |
| Engine, Materials | Xcode 26.6 compile fixes (`self.` capture; a macOS 27 SDK property by key) |
| SwipeReply | the pane controller's window is optional |

## Updating

```bash
scripts/cmux-next/sync-messageslab.sh <commit>       # copy, apply Patches/, record the pin, show the diff
scripts/cmux-next/sync-messageslab.sh --check         # vendored == pin + patches
scripts/cmux-next/sync-messageslab.sh --write-patches # after editing a vendored file by hand
```

A patch that no longer applies stops the sync; fix that file by hand, then
`--write-patches`. Then run the harness on cmux-lawrence-2
(`scripts/cmux-next/home-messageslab-harness.sh`, header): the Home path must
commit MessagesLab's animations byte for byte, and the vendored files must
match the upstream app's `--diff-harness` output.
