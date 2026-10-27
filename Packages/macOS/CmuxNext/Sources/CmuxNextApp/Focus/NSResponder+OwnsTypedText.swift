import AppKit
import CmuxNextTerminal

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

extension WindowController {
    /// A text input has this window's keyboard: an editable AppKit text view or field (empty or not; the person may have
    /// just put the caret there), text an input method composes, or an editable element of the focused page (a web form
    /// field, an editor). Automation does not take the window from it (CLAUDE.md, "Go past Chrome where cmux is
    /// scripted"). A terminal is not a text input here: a person's `cmux open --focus` from a terminal moves on.
    @MainActor var hasTextInputKeyboard: Bool {
        // The person's keyboard is in this window only while the app is active and the key window is this window or one
        // it owns (a Chromium page window, a sheet: the shell itself resigns key then). A CLI run from another app finds
        // the keyboard elsewhere.
        let facts = focus.currentState()
        guard let window, facts.appActive else { return false }
        guard facts.windowKey || NSApp.keyWindow.flatMap(services.windows.owner(of:)) === self else { return false }
        if let responder = window.firstResponder {
            if responder.ownsTypedText { return true }
            if !(responder is TerminalSurfaceView), let client = responder as? any NSTextInputClient, client.hasMarkedText() { return true }
        }
        let router = services.keyRouter
        return router.facts(in: window, controller: self).pageEditableFocused
    }
}
