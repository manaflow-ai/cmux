import AppKit

/// Non-interactive placeholder label hosted by ``FeedInlineTextEditorView``.
///
/// Returns `nil` from `hitTest(_:)` so pointer events fall through to the
/// editor's text view rather than landing on the placeholder overlay.
final class FeedInlinePassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
