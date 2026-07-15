import AppKit

/// Owns the native file-editor view across SwiftUI tab-host remounts.
@MainActor
final class FilePreviewTextEditorSession {
    private var retainedScrollView: NSScrollView?
    private var retainedTextView: SavingTextView?

    func editorViews() -> (scrollView: NSScrollView, textView: SavingTextView) {
        if let retainedScrollView, let retainedTextView {
            return (retainedScrollView, retainedTextView)
        }

        let scrollView = NSScrollView()
        let textView = SavingTextView.makeFilePreviewTextView()
        scrollView.documentView = textView
        retainedScrollView = scrollView
        retainedTextView = textView
        return (scrollView, textView)
    }

    func close() {
        retainedTextView?.delegate = nil
        retainedTextView?.panel = nil
        retainedScrollView?.removeFromSuperview()
        retainedScrollView = nil
        retainedTextView = nil
    }
}
