import AppKit
import CmuxWorkspaces
import SwiftUI

// MARK: - Support

/// Bridges Return / Escape / focus loss on a checklist field to commit and
/// cancel closures — the exact `ChecklistInputField.Coordinator` semantics
/// (focus loss commits non-empty text, Option-Return inserts a newline).
@MainActor
final class SidebarRowChecklistFieldBridge: NSObject, NSTextFieldDelegate {
    private let onCommit: (String) -> Void
    private let onCancel: () -> Void
    /// Invoked ONLY for an explicit Return commit — never for the focus-loss
    /// commit that fires while a field is being torn down or replaced, where
    /// a synchronous re-arm would re-enter the teardown and strand an
    /// untracked editor in the row.
    var onReturnCommit: (() -> Void)?
    /// Invoked after a focus-loss (end-editing) commit. The add field uses
    /// this to clear its committed draft: legacy re-created an empty field
    /// here, and keeping the submitted text armed would double-add it on a
    /// later Return.
    var onEndEditingCommit: (() -> Void)?
    private var committed = false

    init(onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.onCommit = onCommit
        self.onCancel = onCancel
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertLineBreak(_:))
            || selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
            textView.insertText("\n", replacementRange: textView.selectedRange())
            control.stringValue = textView.string
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            committed = true
            onCommit(control.stringValue)
            onReturnCommit?()
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            committed = true
            onCancel()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        let text = (obj.object as? NSTextField)?.stringValue ?? ""
        deferredEndEditingAction(text: text)?()
    }

    /// Claims the field's pending focus-loss result synchronously, then
    /// returns its model mutation for the caller to run after UI teardown.
    func deferredEndEditingAction(text: String) -> (@MainActor () -> Void)? {
        guard !committed else { return nil }
        committed = true
        let onCommit = self.onCommit
        let onCancel = self.onCancel
        let onEndEditingCommit = self.onEndEditingCommit
        return { [weak self] in
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                onCancel()
            } else {
                onCommit(text)
                if let onEndEditingCommit {
                    onEndEditingCommit()
                    // Add-field sessions persist across focus losses (the field
                    // stays armed, legacy parity) — re-open the latch so the
                    // NEXT focus/type/click-away commit is not silently dropped.
                    // Edit-field bridges never set onEndEditingCommit and stay
                    // latched (their session ends with the commit).
                    self?.committed = false
                }
            }
        }
    }

    /// Legacy parity: the checklist fields draw no background — the focused
    /// field editor otherwise paints a dark box over the (blue) row.
    static func clearFieldEditorBackground(_ field: NSTextField) {
        guard let editor = field.currentEditor() as? NSTextView else { return }
        editor.drawsBackground = false
        editor.enclosingScrollView?.drawsBackground = false
    }
}
