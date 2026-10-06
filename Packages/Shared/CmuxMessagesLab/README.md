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
    owner can take a reply: `ChatIntents.canReply`, false until HomeOp has one),
    FlightRecorder (off until the app's policy, `HomeFlightRecorder`, turns it
    on: DEV by default, NIGHTLY by Debug Settings opt-in, never Release or RC).
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
  `HomeMedia` (attachment bubble pictures as `file:` assets MessagesLab's
  row drawing reads: local files first, else `HomeStoreBinding.fetchAttachment`),
  `HomeVideo` (inline video: lane 16's `VideoPlayback` players placed in
  MessagesLab's video bubbles under the bubble mask, with RowDrawing's play
  disc while paused), `CmuxStrings` (Resources/CmuxHome.xcstrings),
  `HomeMarkdown` (an agent's Markdown as MessagesLab text and style runs;
  people's text stays plain), `HomeFlightRecorder` (the flight recorder's
  policy, log folder and Save Last 10 Seconds, plus the helpers it calls from
  unvendored MessagesLab files),
  `FixtureTheme` (cmux theme to Fixture colours), `MessagesLabHomeView`
  (the public view).

## Blocker patches

| file | why |
| --- | --- |
| Springs, Layout, TranscriptAccess, Model (fixture root) | resources live in the package bundle, not the app's main bundle |
| Model, Layout | live dates in the user's zone and locale (fixtures keep -07:00 and en_US) |
| WindowView, Compose | rows and field lines follow the view's own width (several Home tabs), not the process-wide `Metrics.current` |
| Fixture, Transcript, Morph | optional cmux theme; nil keeps MessagesLab's measured palette |
| Fixture | a theme without an accent keeps MessagesLab's measured blue, gradient and white text (`FixtureTheme.measuredAccent`) |
| Fixture, Transcript, Compose | typing dots, placeholder, waveform, caret and chip fill from the theme on a light theme; a dark theme keeps MessagesLab's measured values (the field glass and its buttons follow with the view appearance, `FieldChrome.applyTheme`) |
| HeaderBackdrop | the tint uses the theme background (MessagesLab's grey read as a band on a cmux pane) |
| Layout, Localizable.xcstrings | the placeholder says Message, not iMessage |
| Layout | a failed send that reached the owner unanswered says May Not Have Been Delivered (`CmuxStrings`, Resources/CmuxHome.xcstrings in every app language) |
| Engine, Materials | Xcode 26.6 compile fixes (`self.` capture; a macOS 27 SDK property by key) |
| SwipeReply | the pane controller's window is optional |
| RowDrawing | file, audio, contact and voice memo rows on my side use the theme's sent text colour (white by default; a light accent showed white text) |
| Engine, WindowView | `cmuxSetAttachment`: an attachment part's picture or upload state changed in HomeStore (no content change, no transition; the row redraws in place) |
| Compose | `onPastePasteboard`: the field's paste reaches the host's attachment intake first (Home's type rule, prepared by HomeStore) |
| Layout | styled runs (an agent's Markdown) break lines with the fonts they draw with; `code` runs draw monospaced |
| FlightRecorder | the app's policy and log folder (`HomeFlightRecorder`), window captures behind their own opt-in, the pane's optional window (attached from `ChatController.windowChanged`, observers replaced), FlashCheck/LiveProbes/Bench/LiveRecord helpers from `HomeFlightRecorder` |

## Updating

```bash
scripts/cmux-next/sync-messageslab.sh <commit>       # copy, apply Patches/, record the pin, show the diff
scripts/cmux-next/sync-messageslab.sh --check         # vendored == pin + patches
scripts/cmux-next/sync-messageslab.sh --write-patches # after editing a vendored file by hand
```

A patch that no longer applies stops the sync; fix that file by hand, then
`--write-patches`.

Partial roll-ins: a vendor.tsv row with a third column takes that file from
its own MessagesLab commit (the pin stays for the rest), for upstream commits
that are wip checkpoints. Current per-file pins (2026-10-05): Fixture, Header,
Layout and appkit-native Compose at 7f1a811 (Display P3 palette and measured
colours, wide-colour caret, text thread preview); RowDrawing and Transcript at
4173e9f (colours, WideBitmap); Morph at d163ddf; Materials and TranscriptAccess
at 4173e9f (compose glyphs: plus 15.5 pt, the private emoji.face.grinning
symbol; double-click word selection, P3 selection); Shapes at 25b2ad9 (which
reverts 7dea554's tail refit). Not taken: 4173e9f's catalyst Layout,
Fixture and WindowView and appkit-native Compose (ComposeMetrics' 31 pt field
and the thread work are unfinished there), and every SwipeReply change. Host.swift
is not vendored: 7f1a811's press and hold, picker dim and Esc, double-click
word and menu tapback rows are carried in Cmux/PaneInteractions.swift and
PaneHost; its layout-before-field-chrome fix was already PaneHost's. For the
harness oracle, build MessagesLab from the pin with each pinned file overlaid. Then run the harness on cmux-lawrence-2
(`scripts/cmux-next/home-messageslab-harness.sh`, header): the Home path must
commit MessagesLab's animations byte for byte, and the vendored files must
match the upstream app's `--diff-harness` output.
