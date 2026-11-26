public import AppKit

/// Scroll view backing the feedback message editor. Redirects mouse-down hits to
/// the document text view so clicking anywhere in the field focuses the editor.
public final class FeedbackComposerMessageScrollView: NSScrollView {
    weak var focusTextView: NSTextView?

    public override func mouseDown(with event: NSEvent) {
        if let focusTextView {
            _ = window?.makeFirstResponder(focusTextView)
        }
        super.mouseDown(with: event)
    }
}
