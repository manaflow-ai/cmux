import AppKit

/// The popup location bar's URL text: a label the user can select and copy
/// but not edit. While it has the keyboard it shows the full address
/// (`isShowingFullText`), all selected; leaving it restores the short form.
final class PopupAddressField: NSTextField {
    /// The field took or left the keyboard (true while it shows the full address).
    var onEditingChange: ((Bool) -> Void)?
    private(set) var isShowingFullText = false

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became, !isShowingFullText {
            isShowingFullText = true
            onEditingChange?(true)
        }
        return became
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        guard isShowingFullText else { return }
        isShowingFullText = false
        onEditingChange?(false)
    }

    /// Shows `text` plainly and selects all of it.
    func showFullText(_ text: String) {
        stringValue = text
        currentEditor()?.selectAll(nil)
    }
}
