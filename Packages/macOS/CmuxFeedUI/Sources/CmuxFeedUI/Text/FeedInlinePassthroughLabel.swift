import AppKit

/// A non-interactive `NSTextField` used as the placeholder label inside the
/// inline Feed reply/answer editor. It opts out of hit-testing so clicks fall
/// through to the editor's text view underneath it.
final class FeedInlinePassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
