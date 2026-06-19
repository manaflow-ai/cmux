internal import AppKit

/// Placeholder label for the multiline command-palette editor that never
/// intercepts hit-testing, so clicks fall through to the text view beneath it.
final class CommandPalettePassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
