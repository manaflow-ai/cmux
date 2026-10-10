import AppKit

// Field changes in a dialog with a user-only button (cx-zk9t). An edit is the person's
// only while the app dispatches the person's own key or click in this dialog
// (`CmuxPersonInput.isPersonEdit`). Any other change (an accessibility write, posted
// keys, a password manager's fill) stays, and the field shows "Changed by another app.
// Check it before you continue." so the person sees it before they confirm; the
// confirm itself still needs the person's own press.
extension CmuxDialogView {
    /// The hidden note under field `id`, for a user-only dialog; none otherwise.
    func changeNote(_ id: String, width: CGFloat) -> [NSView] {
        guard spec.userOnlyKind.isUserOnly else { return [] }
        let note = NSTextField(wrappingLabelWithString: CmuxDialogStrings.changedByAnotherApp)
        note.font = Typography.caption
        note.preferredMaxLayoutWidth = width
        note.isHidden = true
        note.identifier = NSUserInterfaceItemIdentifier("cmux.dialog.field.\(id).changedByAnotherApp")
        performWithTheme { note.textColor = Palette.danger }
        note.widthAnchor.constraint(equalToConstant: width).isActive = true
        changeNotes[id] = note
        return [note]
    }

    /// A check box or choice changed (its action).
    @objc func fieldChanged(_ sender: NSControl) { noteChange(of: sender) }

    /// A text field changed (through its field editor, by typing or by any writer).
    public func controlTextDidChange(_ notification: Notification) {
        if let field = notification.object as? NSControl { noteChange(of: field) }
    }

    private func noteChange(of control: NSControl) {
        guard spec.userOnlyKind.isUserOnly, let raw = control.identifier?.rawValue, raw.hasPrefix(Self.fieldPrefix) else { return }
        let id = String(raw.dropFirst(Self.fieldPrefix.count))
        if CmuxPersonInput.shared.isPersonEdit(NSApp.currentEvent, in: window) { return }
        changeNotes[id]?.isHidden = false
        setAccessibilityHelp([accessibilityHelp(), CmuxDialogStrings.changedByAnotherApp].compactMap { $0 }.joined(separator: "\n"))
    }

    private static let fieldPrefix = "cmux.dialog.field."
}
