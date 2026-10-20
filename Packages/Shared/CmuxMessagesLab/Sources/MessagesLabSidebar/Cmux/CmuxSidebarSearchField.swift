public import AppKit

/// The list's search field (MessagesLab's `NSSearchField`, cmux patch): it reports when it takes
/// the keyboard and when its edit ends, so the host can draw its own focus ring and caret instead
/// of AppKit's system-blue ones, and open a collapsed search while it edits.
public final class CmuxSidebarSearchField: NSSearchField {
    /// True when the field takes the keyboard, false when its edit ends.
    public var onEditingChange: ((Bool) -> Void)?

    public override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onEditingChange?(true) }
        return became
    }

    public override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        // Return can select the text again inside `super` (editing goes on): report the state after it.
        onEditingChange?(currentEditor() != nil)
    }

    /// True while the field edits (its field editor is the window's first responder).
    public var isEditing: Bool { currentEditor() != nil }
}
