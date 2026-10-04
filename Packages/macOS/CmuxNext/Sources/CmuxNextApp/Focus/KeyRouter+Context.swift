import AppKit
import CmuxNextActions

// The context keys of the window a key goes to (plans/cmux-next/keybindings.md
// section 4): built from that window's focus, never from the process-wide
// registry context another window published.
extension KeyRouter {
    /// Facts about the focused surface that the focus state does not hold.
    nonisolated struct Facts: Equatable, Sendable {
        /// The key window's first responder has marked text (an input method
        /// is composing).
        var hasMarkedText = false
        /// The focused terminal is in copy mode.
        var terminalCopyMode = false
        /// The focused screen has a primary input and none of its text
        /// fields has the keyboard (`PrimaryInputTarget`).
        var primaryInputReady = false
        /// The focused page cannot take typing yet: its document has not
        /// focused its primary input, or keys typed before still wait.
        var pageInputPending = false
    }

    /// The context keys for a key in a window with `focus`.
    func keyContext(for focus: FocusState, facts: Facts) -> KeyContext {
        Self.keyContext(for: focus, appContext: registry.context, facts: facts)
    }

    /// Pure: the focus-independent bits of `appContext` (signed in, Cloud
    /// workspace, palette open...), the bits `focus` implies, and the
    /// surface keys.
    nonisolated static func keyContext(for focus: FocusState, appContext: ActionContext, facts: Facts) -> KeyContext {
        var bits = appContext.subtracting(ActionContext.focusBits)
        let implied = focus.context
        if implied.terminal { bits.insert(.terminalFocused) }
        if implied.browser { bits.insert(.browserFocused) }
        if implied.agent { bits.insert(.agentPaneFocused) }
        var context = KeyContext(bits: bits)
        context[KeyContext.windowKind] = .string(KeyContext.WindowKindValue.main)
        let resolved = focus.resolved
        if let kind = surfaceKind(resolved) { context[KeyContext.surfaceKind] = .string(kind) }
        context[KeyContext.focus] = .string(focusName(resolved))
        if resolved.isTextInput { context[KeyContext.textInputFocus] = .bool(true) }
        if focus.isBrowserFocusModeActive { context[KeyContext.browserFocusMode] = .bool(true) }
        if facts.terminalCopyMode, case .terminal = resolved { context[KeyContext.terminalCopyMode] = .bool(true) }
        return context
    }

    /// `surfaceKind`: what has the keyboard; nil outside a pane.
    nonisolated static func surfaceKind(_ resolved: FocusState.Resolved) -> String? {
        switch resolved {
        case .terminal: "terminal"
        case .browserPage, .addressBar, .findBar, .devTools: "page"
        case .agentPage: "agent"
        case .conversation: "home"
        case .page(_, let tab): internalPageKind(tab)
        case .emptyPane: "empty"
        case .overlay(.palette): "palette"
        case .sidebar, .sidebarField, .textField, .overlay, .none: nil
        }
    }

    /// An internal page's `surfaceKind`: `settings` (Settings, Debug
    /// Settings), `appStore`, else the page id (`tasks`, `inbox`).
    nonisolated static func internalPageKind(_ tab: String) -> String {
        switch LocalPageTab.page(of: tab)?.rawValue {
        case "settings", "debug-settings": "settings"
        case "app-store": "appStore"
        case let id?: id
        case nil: "internalPage"
        }
    }

    /// `focus`: the keyboard target.
    nonisolated static func focusName(_ resolved: FocusState.Resolved) -> String {
        switch resolved {
        case .terminal, .browserPage, .agentPage, .page, .conversation, .emptyPane: "content"
        case .addressBar: "omnibar"
        case .findBar: "findBar"
        case .devTools: "devTools"
        case .sidebar: "sidebar"
        case .sidebarField: "sidebarField"
        case .textField: "textField"
        case .overlay: "overlay"
        case .none: "none"
        }
    }

    /// The facts of `window` (the key window) and its cmux window.
    func facts(in window: NSWindow, controller: WindowController) -> Facts {
        Facts(hasMarkedText: (window.firstResponder as? any NSTextInputClient)?.hasMarkedText() == true,
              terminalCopyMode: terminalCopyMode(in: controller))
    }

    private func terminalCopyMode(in controller: WindowController) -> Bool {
        guard case .terminal(let pane, _) = controller.focus.state.resolved,
              case .terminal(let entry)? = controller.content?.paneController(key: pane)?.currentContent else { return false }
        return entry.session.surfaceView.isCopyModeActive
    }
}
