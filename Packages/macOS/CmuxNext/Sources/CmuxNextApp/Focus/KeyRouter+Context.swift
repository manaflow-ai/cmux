import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextPages

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
        /// The focused React page's id (`cmux.markdown`): context key
        /// `pageId`; the markdown page also sets `markdownFocused`.
        var pageID: String?
        /// A list-like control in the focused page has the keyboard (R85;
        /// the sidebar list and its field imply it without this).
        var listFocus = false
        /// An editable element in the focused page has the keyboard (a text
        /// field, Monaco, a content-editable): bare keys are typing there.
        var pageEditableFocused = false
        /// The focused address bar shows its suggestion list: it is a list
        /// for Ctrl-N/P/J/K (R110) until the list closes.
        var omnibarListOpen = false
        /// The focused internal page's id when its tab id does not name it
        /// (a store page tab, `page-tabs-v1`).
        var internalPage: String?
    }

    /// The markdown page's id (`PageDescriptor.markdown`), for the
    /// `markdownFocused` bit.
    nonisolated static let markdownPageID = "cmux.markdown"
    /// The diff viewer page: `diffViewerFocused`, which owns bare keys.
    nonisolated static let diffPageID = "cmux.diff"
    /// The code editor page (Monaco): `codeEditorFocused`.
    nonisolated static let codeEditorPageID = "cmux.editor"

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
        if case .addressBar = focus.resolved { bits.insert(.omnibarFocused) }
        if facts.pageID == Self.markdownPageID { bits.insert(.markdownFocused) }
        if facts.pageID == Self.diffPageID { bits.insert(.diffViewerFocused) }
        if facts.pageID == Self.codeEditorPageID { bits.insert(.codeEditorFocused) }
        var context = KeyContext(bits: bits)
        if let page = facts.pageID { context[KeyContext.pageID] = .string(page) }
        context[KeyContext.windowKind] = .string(KeyContext.WindowKindValue.main)
        let resolved = focus.resolved
        if let kind = surfaceKind(resolved, internalPage: facts.internalPage) { context[KeyContext.surfaceKind] = .string(kind) }
        context[KeyContext.focus] = .string(focusName(resolved))
        if resolved.isTextInput || facts.pageEditableFocused { context[KeyContext.textInputFocus] = .bool(true) }
        if focus.isBrowserFocusModeActive { context[KeyContext.browserFocusMode] = .bool(true) }
        if facts.terminalCopyMode, case .terminal = resolved { context[KeyContext.terminalCopyMode] = .bool(true) }
        let omnibarList = facts.omnibarListOpen && { if case .addressBar = resolved { true } else { false } }()
        if facts.listFocus || omnibarList || Self.isNativeList(resolved) { context[KeyContext.listFocus] = .bool(true) }
        return context
    }

    /// `surfaceKind`: what has the keyboard; nil outside a pane.
    nonisolated static func surfaceKind(_ resolved: FocusState.Resolved, internalPage: String? = nil) -> String? {
        switch resolved {
        case .terminal: "terminal"
        case .browserPage, .addressBar, .findBar, .devTools: "page"
        case .agentPage: "agent"
        case .conversation: "home"
        case .page(_, let tab): internalPageKind(tab, page: internalPage)
        case .emptyPane: "empty"
        case .overlay(.palette): "palette"
        case .sidebar, .sidebarField, .textField, .overlay, .none: nil
        }
    }

    /// An internal page's `surfaceKind`: `settings` (Settings, Debug
    /// Settings), `appStore`, else the page id (`tasks`, `inbox`). `page`
    /// names the page of a tab whose id does not.
    nonisolated static func internalPageKind(_ tab: String, page: String? = nil) -> String {
        switch LocalPageTab.page(of: tab)?.rawValue ?? page {
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
              terminalCopyMode: terminalCopyMode(in: controller), pageID: focusedPage(in: controller)?.descriptor.id,
              listFocus: focusedReadiness(in: controller)?.isListFocused == true,
              pageEditableFocused: focusedReadiness(in: controller)?.isEditableFocused == true,
              omnibarListOpen: focusedAddressBar(in: controller)?.isShowingSuggestions == true,
              internalPage: focusedInternalPage(in: controller))
    }

    /// The page id of the focused internal page tab.
    private func focusedInternalPage(in controller: WindowController) -> String? {
        guard case .page = controller.focus.state.resolved, let pane = controller.focus.state.resolved.pane,
              case .page(let view)? = controller.content?.paneController(key: pane)?.currentContent else { return nil }
        return view.page.rawValue
    }

    /// The sidebar list and its search field are lists for Ctrl-N/P/J/K.
    nonisolated static func isNativeList(_ resolved: FocusState.Resolved) -> Bool {
        switch resolved {
        case .sidebar, .sidebarField: true
        default: false
        }
    }

    private func focusedReadiness(in controller: WindowController) -> PageInputReadiness? {
        guard let pane = controller.focus.state.resolved.pane else { return nil }
        return controller.content?.paneController(key: pane)?.currentContent?.inputReadiness
    }

    /// The focused pane's address bar while it has the keyboard.
    private func focusedAddressBar(in controller: WindowController) -> AddressBarView? {
        guard case .addressBar = controller.focus.state.resolved, let pane = controller.focus.state.resolved.pane,
              case .browser(let entry)? = controller.content?.paneController(key: pane)?.currentContent else { return nil }
        return entry.chrome.addressBar
    }

    /// The React page the focused pane's selected tab shows, if any.
    func focusedPage(in controller: WindowController) -> PageWebView? {
        guard case .page(_, _) = controller.focus.state.resolved, let pane = controller.focus.state.resolved.pane,
              case .page(let view)? = controller.content?.paneController(key: pane)?.currentContent else { return nil }
        return view.content as? PageWebView
    }

    private func terminalCopyMode(in controller: WindowController) -> Bool {
        guard case .terminal(let pane, _) = controller.focus.state.resolved,
              case .terminal(let entry)? = controller.content?.paneController(key: pane)?.currentContent else { return false }
        return entry.session.surfaceView.isCopyModeActive
    }
}
