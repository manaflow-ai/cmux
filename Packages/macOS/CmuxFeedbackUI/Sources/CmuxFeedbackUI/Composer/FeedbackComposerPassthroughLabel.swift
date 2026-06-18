import AppKit

/// Placeholder label that ignores hit-testing so clicks pass through to the
/// editor's text view underneath.
final class FeedbackComposerPassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
