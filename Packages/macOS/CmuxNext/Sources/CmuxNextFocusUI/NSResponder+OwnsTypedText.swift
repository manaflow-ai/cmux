public import AppKit

extension NSResponder {
    /// A text input the person can type into has the keyboard: a text view
    /// or field (or a field's editor) that is editable, in a window and not
    /// hidden. Typed text is its own. A hidden field that kept the keyboard
    /// (Home's Chief settings name after the panel closed), a read-only text
    /// view or a detached one is not a place to type: a surface's primary
    /// input takes the keys instead (`PrimaryInputTarget`).
    @MainActor public var ownsTypedText: Bool {
        guard let view = self as? NSView, view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return false }
        if let text = view as? NSText { return text.isEditable }
        if let field = view as? NSTextField { return field.isEditable }
        return false
    }
}

extension NSWindow {
    /// The window's first responder is a text input the person types in: an editable AppKit text view or field (empty
    /// or not: the person may have just put the caret there, ``NSResponder/ownsTypedText``), or a responder an input
    /// method composes text in, unless `excluded` says it is no text input (a terminal: a person's `cmux open --focus`
    /// run from a terminal moves on). Automation does not take a window from such a responder (CLAUDE.md, "Go past
    /// Chrome where cmux is scripted"); a focused page's editable element is the caller's to add.
    @MainActor public func firstResponderTypesText(excluding excluded: (NSResponder) -> Bool) -> Bool {
        guard let responder = firstResponder else { return false }
        if responder.ownsTypedText { return true }
        return !excluded(responder) && (responder as? any NSTextInputClient)?.hasMarkedText() == true
    }
}
