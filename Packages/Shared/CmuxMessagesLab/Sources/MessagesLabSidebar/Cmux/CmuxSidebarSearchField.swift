public import AppKit

/// The list's search field (MessagesLab's `NSSearchField`, cmux patch): it reports when it takes
/// the keyboard and when its edit ends, so the host can draw its own focus ring and caret instead
/// of AppKit's system-blue ones, and open a collapsed search while it edits.
public final class CmuxSidebarSearchField: NSSearchField {
    /// Its text centred on one line when unbezeled (``CmuxSidebarSearchFieldCell``).
    public override class var cellClass: AnyClass? {
        get { CmuxSidebarSearchFieldCell.self }
        set {}
    }

    /// True when the field takes the keyboard, false when its edit ends.
    public var onEditingChange: ((Bool) -> Void)?
    /// The text changed (typing, the cancel button, a host's `stringValue`): a host whose layout
    /// depends on an empty field re-lays out.
    public var onTextChange: (() -> Void)?

    public override var stringValue: String {
        didSet { onTextChange?() }
    }

    public override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        onTextChange?()
    }

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

    // The placeholder as set; the field shows it only when it fits whole beside the magnifier. A field
    // too narrow for it (the narrow Home list's open search) shows the magnifier alone, never a
    // clipped "Searc" (the user, 2026-11-03, msg 20149).
    private var wantedPlaceholder: String?
    private var wantedAttributedPlaceholder: NSAttributedString?

    public override var placeholderString: String? {
        get { super.placeholderString }
        set { wantedPlaceholder = newValue; wantedAttributedPlaceholder = nil; showPlaceholderIfItFits() }
    }

    public override var placeholderAttributedString: NSAttributedString? {
        get { super.placeholderAttributedString }
        set { wantedAttributedPlaceholder = newValue; showPlaceholderIfItFits() }
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        showPlaceholderIfItFits()
    }

    /// The placeholder's room: the text rect beside the magnifier (and the cancel button).
    private var placeholderRoom: CGFloat {
        (cell as? NSSearchFieldCell)?.searchTextRect(forBounds: bounds).width ?? bounds.width
    }

    private func showPlaceholderIfItFits() {
        if let attributed = wantedAttributedPlaceholder {
            let shown = attributed.size().width <= placeholderRoom ? attributed : nil
            if shown == nil, super.placeholderString != nil { super.placeholderString = nil } // no plain fallback
            if super.placeholderAttributedString != shown { super.placeholderAttributedString = shown }
            return
        }
        let width = font.flatMap { font in wantedPlaceholder.map { ($0 as NSString).size(withAttributes: [.font: font]).width } } ?? 0
        let shown = width <= placeholderRoom ? wantedPlaceholder : nil
        if super.placeholderString != shown { super.placeholderString = shown }
    }
}
