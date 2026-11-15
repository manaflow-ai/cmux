# Pressed State Changes Only The Fill

A held button (mousedown, a touch, a web `:active`, a held frame, a SwiftUI `configuration.isPressed`, an
AppKit `isPressed` or `isHighlighted`) looks like its hover with a different background fill, and nothing else
(Lawrence 2026-11-15: "we only want to have different bg color on mousedown"). The design rule and the shared
looks are in `design/pressed-state.md`; `scripts/cmux-next/check-pressed-state.py` catches the plain cases.

Report a failure when the diff makes a pressed state change anything but the background:

- The label's weight, font, size or letter spacing (bold on press, `font-weight` on `:active`, `.fontWeight`,
  `.bold()`, `NSFont.boldSystemFont` or a different `font` while pressed).
- The button's size, padding or place: `transform`, `scale`, `translate`, `.scaleEffect`, `.offset`,
  `CATransform3D` or `CGAffineTransform` while pressed, a press "sink" or "shrink".
- The label's or icon's opacity or alpha (`.opacity`, `alphaValue`, `fill.alpha`), or a different symbol or
  image while pressed.
- A pressed look set outside the shared looks: a helper that returns a different font or transform for
  `pressed`, a JavaScript handler that adds a class or a style on `pointerdown`/`mousedown`, a new SwiftUI
  `.buttonStyle(.plain)`, `.borderless` or `.link` (they dim the label), or a hand-drawn pressed fill where
  `ChromeHover`, `.buttonStyle(.cmuxPressFill)` (macOS and iOS) or `.ui-btn` would do.
- An on toggle (`aria-pressed="true"`, Base UI `data-pressed`) that changes weight, size or transform when it
  turns on.

Allowed cases:

- A different background fill while pressed, including a wash over the rest fill.
- A press rule that only repeats the hover's look (`:is(:hover, :active)`), or that takes a ring, edge or
  shadow away (`box-shadow: none`).
- A selected (on) toggle's fill and ink.
- Drag handles, sliders and other controls that follow the pointer rather than being pressed, and a reasoned
  `pressed-state: allow <reason>` exception.
- Tests, galleries and prototypes.

Report the file, the line, what the press changes, and the shared look to use instead.
