# Terminal Scroll Lab

This standalone iOS app embeds the same `GhosttySurfaceView` and `GhosttyKit` renderer used by cmux, feeds it an 800-row local fixture, and places a transparent native `UIScrollView` above it.

UIKit owns touch tracking, rubber-band overdrag, velocity, acceleration, and deceleration. The lab forwards continuous fractional-row deltas to Ghostty and translates the rendered surface only by the sub-row remainder. No custom easing curve, display link, row-snapping gesture recognizer, or delayed synchronization participates in the physics.

The header reports the native scroll phase, point offset, and live renderer translation. Drag slowly to verify individual-pixel motion, pull past either edge to verify rubber-banding, then fling to compare native deceleration.

Generate the project with `xcodegen generate`, then build the `TerminalScrollLab` scheme.
