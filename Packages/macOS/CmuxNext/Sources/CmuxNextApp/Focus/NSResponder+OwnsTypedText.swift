import AppKit

extension NSResponder {
    /// A text input the person can type into has the keyboard: a text view
    /// or field (or a field's editor) that is editable, in a window and not
    /// hidden. Typed text is its own. A hidden field that kept the keyboard
    /// (Home's Chief settings name after the panel closed), a read-only text
    /// view or a detached one is not a place to type: a surface's primary
    /// input takes the keys instead (`PrimaryInputTarget`).
    @MainActor var ownsTypedText: Bool {
        guard let view = self as? NSView, view.isShownForInput else { return false }
        if let text = view as? NSText { return text.isEditable }
        if let field = view as? NSTextField { return field.isEditable }
        return false
    }
}

extension NSView {
    /// Whether AppKit can give this view a key or a click now: it is in a window and neither it nor an ancestor is
    /// hidden. Key routing asks the view tree, not the scheduler's `VisibilityNode`: `makeFirstResponder` and
    /// `hitTest` read the same hidden flags (a node can lag the tree for a frame, and an occluded window still
    /// takes keys). Chromium's focus manager asks the view the same way (`views::View::IsFocusable`,
    /// ui/views/view.cc: enabled, drawn and visible up the tree).
    var isShownForInput: Bool {
        // visibility-walk-allow: key routing and hit tests follow AppKit's own hidden flags, which decide where a key goes
        window != nil && !isHiddenOrHasHiddenAncestor
    }
}
