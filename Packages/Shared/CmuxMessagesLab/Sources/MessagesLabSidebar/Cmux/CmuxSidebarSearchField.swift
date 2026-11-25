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
        // The field takes the keyboard in its last frame, which can be wider than the one it opens
        // in (the avatar-only list's open search): the placeholder's room is measured again.
        if became { showPlaceholderIfItFits(); onEditingChange?(true) }
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
        showCancelIfItFits()
        showPlaceholderIfItFits()
    }

    /// The narrowest field that keeps its clear button: under it the button took the little room
    /// the typed text had and sat over it (the user, 2026-11-23: "remove the x from here when its
    /// small"). Escape still clears the field.
    static let cancelMinimumWidth: CGFloat = 100
    /// AppKit's clear button while a narrow field hides it.
    private var hiddenCancel: NSButtonCell?

    private func showCancelIfItFits() {
        guard let cell = cell as? NSSearchFieldCell else { return }
        if bounds.width < Self.cancelMinimumWidth {
            guard let cancel = cell.cancelButtonCell else { return }
            hiddenCancel = cancel
            cell.cancelButtonCell = nil
        } else if cell.cancelButtonCell == nil, let cancel = hiddenCancel {
            cell.cancelButtonCell = cancel
            hiddenCancel = nil
        }
        needsDisplay = true
    }

    /// The placeholder's room: the text rect beside the magnifier, short of the cancel button the
    /// field shows while it edits, less the field editor's line padding. While the field edits the
    /// editor draws the placeholder, and in a narrow field it clipped it to "S" (the user, 2026-11-23).
    private var placeholderRoom: CGFloat {
        guard let cell = cell as? NSSearchFieldCell else { return bounds.width }
        let text = cell.searchTextRect(forBounds: bounds)
        let cancel = cell.cancelButtonRect(forBounds: bounds)
        let end = cancel.width > 0 ? min(text.maxX, cancel.minX) : text.maxX
        return max(0, end - text.minX - 2 * Self.editorLinePadding)
    }

    /// NSTextContainer's default line fragment padding, each side of the field editor's text.
    private static let editorLinePadding: CGFloat = 5

    private func showPlaceholderIfItFits() {
        // While the field edits, its editor drew the placeholder when editing began, often in the
        // field's last, wider frame; a change since leaves that drawing ("S" after the caret, the
        // user 2026-11-23) until the editor draws again.
        // A hidden placeholder is an empty one, not nil: a nil placeholder set while the field edits
        // leaves the field editor drawing the old one (measured on macOS 26), an empty one clears it.
        defer { currentEditor()?.needsDisplay = true }
        let none = NSAttributedString(string: "")
        if let attributed = wantedAttributedPlaceholder {
            let shown = attributed.size().width <= placeholderRoom ? attributed : none
            if shown == none, super.placeholderString != nil { super.placeholderString = nil } // no plain fallback
            if super.placeholderAttributedString != shown { super.placeholderAttributedString = shown }
            return
        }
        let width = font.flatMap { font in wantedPlaceholder.map { ($0 as NSString).size(withAttributes: [.font: font]).width } } ?? 0
        if width <= placeholderRoom {
            if super.placeholderString != wantedPlaceholder { super.placeholderString = wantedPlaceholder }
        } else if super.placeholderAttributedString != none {
            super.placeholderAttributedString = none
        }
    }
}
