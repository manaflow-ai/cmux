# Glass over live terminal content

Leo: "WHERE IS THE IOS FUCKING GLASS REFRACTION FISHEYE"

Trace: `ask-d547ac77f0`. Baseline: `67ddfde57e50cbe6b2c6554435f5e7584e26ea74`.

## Pattern and change

A native glass control cannot refract the live content if an opaque sibling
stands between them. In `TerminalViewController`, `bottomBacking` covered the
terminal rows from the composer's top to the bottom of the page. Place it behind
the scroll view instead. The composer's existing regular glass and native soft
scroll edge retain contrast; the 24-point fade above the dock stays in place.
Full-screen terminal apps keep their separate clipping and below-grid cover.

Replay and foreground stills must remain above the content and below the dock.
Their insertion anchor is now `bottomFade`, not the relocated backing. Capture
only the visible terminal host, so an old composer or key row is not refracted
through the live glass after the keyboard moves. No
setting, glass style, gesture, layout constraint or motion behavior changes.

This follows [SPEC §2.4](../design/SPEC.md) and Apple's
[Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
and [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)
guidance: regular native glass on controls, content behind them, system contrast
and accessibility behavior. Chat, Chief and TabsKit already have native glass
over their full-height content; they need no extra glass layer.

## Detector and acceptance

Use `AllUIStatesSurfacesCaptureUITests/testTerminal` with video on the same
simulator harness before and after the change. Inspect `scrolled-back-jump`,
`composer-open`, `keyboard-up-armed-draft`, and the `terminal-tour` TUI frames.
Also run `TerminalComposerDockUITests`, `TerminalKeyboardToggleFlickerUITests`
and `TerminalResizeDemoUITests`; inspect the foreground 150 ms and 2 s frames
for stale chrome under the live composer.
The scrolled rows must reach the glass edge and visibly refract, the composer
must remain legible, and keyboard/TUI transitions must retain their clipping.
Also inspect `AgentChatJumpCaptureUITests` and
`AgentComposerPickersCaptureUITests` as unchanged chat/menu references.
Static layer order alone does not prove the visual result.

Baseline fleet steps:

- `028408ff6ee1a225757a132e`: composer, workspace and settings stills.
- `11f07b01c3124077c992b4b8`: scroll/menu/terminal captures and video.

Both later completed. Final-head step `5a379546814e454b8d93dd54` at
`dbd77150a475` passed 18 tests, 0 failed, 0 skipped (iPhone 17 Pro, iOS 26.5).
In the scrolled-back and keyboard-up reading frames, terminal rows continue
under the composer and key row and bend at the glass edge; the foreground
150 ms and 2 s frames are byte-identical, with no stale chrome. Stills and
hashes: cmuxterm-hq `docs/findings/evidence/ios-glass-refraction/`.
After captures, run `cmux-next-ios/scripts/review.sh --tag ios-glass-refraction`
from a signed-in Mac origin to obtain the required physical iPhone receipt.
The lane VM cannot substitute simulator evidence for that phone handoff.
