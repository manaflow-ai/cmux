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

    /// Creates the delegate coordinator that bridges field-editor commands and
    /// focus loss to the `onCommit` / `onCancel` closures.
    func makeCoordinator() -> Coordinator {
        Coordinator(onCommit: onCommit, onCancel: onCancel)
    }

    /// Builds the borderless, single-line text field seeded with `initialText`
    /// and wired to the coordinator.
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

    /// Refreshes the coordinator's closures and the field's driven visual and
    /// accessibility state on each parent update (never its text — see below).
    func updateNSView(_ nsView: InlineRenameTextField, context: Context) {
        context.coordinator.onCommit = onCommit
        context.coordinator.onCancel = onCancel
        // Keep driven visual/accessibility state in sync (NSViewRepresentable
        // convention). initialText/stringValue is intentionally NOT synced here:
        // doing so would reset the cursor and clobber in-progress typing.
        nsView.font = .systemFont(ofSize: fontSize, weight: .semibold)
        nsView.placeholderString = placeholder
        nsView.setAccessibilityLabel(accessibilityLabel)
    }

    /// Focuses and selects-all exactly when it enters a window — no async timing
    /// hack (architectural-rethink rule).
    final class InlineRenameTextField: NSTextField {
        /// Becomes first responder and selects the whole name as soon as the
        /// field enters a window, so typing immediately replaces the old name.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            window?.makeFirstResponder(self)
            currentEditor()?.selectAll(nil)
        }
    }

    /// `NSTextFieldDelegate` that resolves field-editor commands into commit,
    /// cancel, or caret-move actions and guarantees the rename resolves at most
    /// once across Enter, Escape, and focus loss.
    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
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

        /// Cancels the rename once, discarding the draft (idempotent via `hasResolved`).
        private func cancelOnce() {
            guard !hasResolved else { return }
            hasResolved = true
            onCancel()
        }

        /// Routes field-editor commands (Enter / Escape) through the resolver,
        /// committing, cancelling, or moving the caret to the start as resolved.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
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

        /// Treats focus loss (e.g. clicking another row) as a commit, unless
        /// Enter or Escape already resolved the edit.
        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSControl else { return }
            commitOnce(field)
        }
    }
}
