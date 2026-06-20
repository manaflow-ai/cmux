import AppKit
import SwiftUI

/// Single-line AppKit text field used for inline workspace renaming in the
/// sidebar. SwiftUI's `TextField` can't control selection/caret or distinguish a
/// first vs second Escape, so this bridges `NSTextField`. Inputs are value +
/// closures only (no store reference), per the sidebar snapshot-boundary rule.
struct SidebarInlineRenameField: NSViewRepresentable {
    let initialText: String
    let fontSize: CGFloat
    let accessibilityLabel: String
    let placeholder: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCommit: onCommit, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> InlineRenameTextField {
        let field = InlineRenameTextField(string: initialText)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.font = .systemFont(ofSize: fontSize, weight: .semibold)
        field.placeholderString = placeholder
        field.setAccessibilityLabel(accessibilityLabel)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: InlineRenameTextField, context: Context) {
        context.coordinator.onCommit = onCommit
        context.coordinator.onCancel = onCancel
    }

    /// Focuses and selects-all exactly when it enters a window — no async timing
    /// hack (architectural-rethink rule).
    final class InlineRenameTextField: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            window?.makeFirstResponder(self)
            currentEditor()?.selectAll(nil)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onCommit: (String) -> Void
        var onCancel: () -> Void
        private let resolver = SidebarInlineRenameKeyResolver()
        private var hasResolved = false

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

        private func cancelOnce() {
            guard !hasResolved else { return }
            hasResolved = true
            onCancel()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            let selectionIsCollapsed = textView.selectedRange().length == 0
            switch resolver.action(for: commandSelector, selectionIsCollapsed: selectionIsCollapsed) {
            case .commit:
                commitOnce(control)
                return true
            case .caretToStart:
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                return true
            case .cancel:
                cancelOnce()
                return true
            case .passThrough:
                return false
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            // Focus loss (click elsewhere) commits, unless Enter/Escape already resolved.
            guard let field = obj.object as? NSControl else { return }
            commitOnce(field)
        }
    }
}
