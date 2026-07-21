import AppKit
import CmuxWorkspaces
import SwiftUI

// MARK: - Support

/// Transparent full-frame click target (the tap-to-edit overlay on item
/// text; legacy: `.contentShape(Rectangle()).onTapGesture`).
@MainActor
final class SidebarRowChecklistTransparentButton: NSControl {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        // Swallow so the table row action does not also fire.
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onClick?()
    }

    /// VoiceOver/keyboard activation parity with the legacy SwiftUI Button.
    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick()
        return true
    }
}

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
        guard !committed else { return }
        committed = true
        let text = (obj.object as? NSTextField)?.stringValue ?? ""
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
                committed = false
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

/// The checklist add/edit field: `FocusGrabbingTextField` that also clears
/// the field editor's background AFTER the focus grab. The immediate clear
/// at creation only covers cells configured while already in a window —
/// `tableView(_:viewFor:row:)` configures BEFORE window attachment, and the
/// editor created by the deferred focus grab would otherwise restore the
/// oversized dark editor box.
@MainActor
final class SidebarRowChecklistFocusField: FocusGrabbingTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        SidebarRowChecklistFieldBridge.clearFieldEditorBackground(self)
    }
}
