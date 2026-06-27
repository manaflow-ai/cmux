import AppKit

/// `NSTextFieldDelegate` that resolves field-editor commands into commit,
/// cancel, or caret-move actions and guarantees the rename resolves at most
/// once across Enter, Escape, and focus loss.
@MainActor
final class SidebarInlineRenameCoordinator: NSObject, NSTextFieldDelegate {
    var onCommit: (String) -> Void
    var onCancel: () -> Void
    private let resolver = SidebarInlineRenameKeyResolver()
    private var hasResolved = false
    private var hasMovedCaretToStart = false

    /// Creates a coordinator bound to the commit and cancel closures.
    init(onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.onCommit = onCommit
        self.onCancel = onCancel
    }

    /// Commit/cancel fire exactly once: Enter, Escape, and focus-loss can all
    /// reach here, but only the first wins.
    private func commitOnce(_ field: NSControl) {
        guard !hasResolved else { return }
        hasResolved = true
        onCommit(field.stringValue)
    }

    /// Cancels the rename once, discarding the draft.
    private func cancelOnce() {
        guard !hasResolved else { return }
        hasResolved = true
        onCancel()
    }

    /// Routes field-editor commands through the resolver.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }

        switch resolver.action(for: commandSelector, hasMovedCaretToStart: hasMovedCaretToStart) {
        case .commit:
            commitOnce(control)
            return true
        case .caretToStart:
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            hasMovedCaretToStart = true
            return true
        case .cancel:
            cancelOnce()
            return true
        case .passThrough:
            return false
        }
    }

    /// Treats focus loss as a commit, unless Enter or Escape already resolved.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSControl else { return }
        commitOnce(field)
    }
}
