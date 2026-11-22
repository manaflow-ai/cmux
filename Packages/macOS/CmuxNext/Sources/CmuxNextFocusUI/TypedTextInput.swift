public import AppKit

public extension NSResponder {
    /// A text input the person can type into has the keyboard: a text view
    /// or field (or a field's editor) that is editable, in a window and not
    /// hidden. Typed text is its own. A hidden field that kept the keyboard
    /// (Home's Chief settings name after the panel closed), a read-only text
    /// view or a detached one is not a place to type: a surface's primary
    /// input takes the keys instead (the App's `PrimaryInputTarget`).
    @MainActor var ownsTypedText: Bool {
        guard let view = self as? NSView, view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return false }
        if let text = view as? NSText { return text.isEditable }
        if let field = view as? NSTextField { return field.isEditable }
        return false
    }
}

public extension NSWindow {
    /// Whether a text input has the person's keyboard in this window: only while the app is active (`appActive`) and this
    /// window or one it owns (a page window, a sheet) is key (`ownsKey`, the focus model's facts). An editable text view or
    /// field (empty or not), text an input method composes in a view that is not a terminal (`isTerminal`), or an editable
    /// element of the focused page (`pageEditable`, read last). Automation does not take the window from it.
    @MainActor func textInputHasKeyboard(appActive: Bool, ownsKey: Bool, isTerminal: (NSResponder) -> Bool,
                                         pageEditable: () -> Bool) -> Bool {
        guard appActive, ownsKey else { return false }
        if firstResponder?.ownsTypedText == true { return true }
        if let responder = firstResponder, !isTerminal(responder), (responder as? any NSTextInputClient)?.hasMarkedText() == true { return true }
        return pageEditable()
    }
}
