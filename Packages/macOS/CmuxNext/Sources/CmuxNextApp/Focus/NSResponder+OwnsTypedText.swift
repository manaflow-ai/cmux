import AppKit

extension NSResponder {
    /// A text input the person can type into has the keyboard: a text view
    /// or field (or a field's editor) that is editable, in a window and not
    /// hidden. Typed text is its own. A hidden field that kept the keyboard
    /// (Home's Chief settings name after the panel closed), a read-only text
    /// view or a detached one is not a place to type: a surface's primary
    /// input takes the keys instead (`PrimaryInputTarget`).
    @MainActor var ownsTypedText: Bool {
        guard let view = self as? NSView, view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return false }
        if let text = view as? NSText { return text.isEditable }
        if let field = view as? NSTextField { return field.isEditable }
        return false
    }
}
