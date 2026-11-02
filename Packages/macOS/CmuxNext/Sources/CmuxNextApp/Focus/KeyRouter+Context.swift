import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextPages
import CmuxNextFocus
import CmuxNextSidebar
import CmuxNextTerminal

// The context keys of the window a key goes to (plans/cmux-next/keybindings.md
// section 4): built from that window's focus, never from the process-wide
// registry context another window published.
extension KeyRouter {
    /// Facts about the focused surface that the focus state does not hold (`KeyFacts`).
    typealias Facts = KeyFacts

    /// The markdown page's id (`PageDescriptor.markdown`), for the
    /// `markdownFocused` bit (with `markdownReadOnlyFocused` or `markdownEditorFocused`).
    nonisolated static let markdownPageID = "cmux.markdown"
    /// The diff viewer page: `diffViewerFocused`, which owns bare keys.
    nonisolated static let diffPageID = "cmux.diff"
    /// The code editor page (Monaco): `codeEditorFocused`.
    nonisolated static let codeEditorPageID = "cmux.editor"
    /// The phone tab's page kind (`InternalPageID.phone`): `simulatorFocused`.
    nonisolated static let phonePageKind = "phone"

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
        bits.formUnion(pageContext(pageID: facts.pageID, markdownReadOnly: facts.markdownReadOnly))
        if facts.textBoxFocused { bits.insert(.textBoxFocused) }
        if isPhone(focus.resolved, internalPage: facts.internalPage) { bits.insert(.simulatorFocused) }
        if facts.fileExplorerFocused { bits.insert(.fileExplorerFocused) }
        var context = KeyContext(bits: bits)
        if let page = facts.pageID { context[KeyContext.pageID] = .string(page) }
        context[KeyContext.windowKind] = .string(KeyContext.WindowKindValue.main)
        let resolved = focus.resolved
        // A top page (Home) fills the content area without a pane: it names the surface.
        if let kind = facts.topPage ?? surfaceKind(resolved, internalPage: facts.internalPage) {
            context[KeyContext.surfaceKind] = .string(kind)
        }
        if let page = facts.topPage { context[KeyContext.topPage] = .string(page) }
        context[KeyContext.focus] = .string(focusName(resolved))
        if resolved.isTextInput || facts.pageEditableFocused { context[KeyContext.textInputFocus] = .bool(true) }
        if focus.isBrowserFocusModeActive { context[KeyContext.browserFocusMode] = .bool(true) }
        if facts.terminalCopyMode, case .terminal = resolved { context[KeyContext.terminalCopyMode] = .bool(true) }
        if facts.terminalAlternateScreen, case .terminal = resolved { context[KeyContext.terminalAlternateScreen] = .bool(true) }
        let omnibarList = facts.omnibarListOpen && { if case .addressBar = resolved { true } else { false } }()
        if facts.listFocus || omnibarList || Self.isNativeList(resolved) { context[KeyContext.listFocus] = .bool(true) }
        if facts.sidebarMultiSelection, case .sidebar = resolved { context[KeyContext.sidebarMultiSelection] = .bool(true) }
        if facts.workspacesAsTabs { context[KeyContext.workspacesAsTabs] = .bool(true) }
        return context
    }

    /// The context bits a focused page with `pageID` sets (the markdown, diff viewer and code editor pages).
    nonisolated static func pageContext(pageID: String?, markdownReadOnly: Bool) -> ActionContext {
        switch pageID {
        case markdownPageID?: .markdown(readOnly: markdownReadOnly)
        case diffPageID?: .diffViewerFocused
        case codeEditorPageID?: .codeEditorFocused
        default: []
        }
    }

    /// Whether a focused page with `pageID` can own bare keys (``ActionContext/bareKeyOwners``), in the
    /// most permissive reading of its facts (a markdown page read-only): the cheap check before the facts.
    nonisolated static func pageMayOwnBareKeys(_ pageID: String) -> Bool {
        !pageContext(pageID: pageID, markdownReadOnly: true).isDisjoint(with: .bareKeyOwners)
    }

    /// Whether a phone tab has the keyboard (`simulatorFocused`: the Simulator shortcuts).
    nonisolated static func isPhone(_ resolved: FocusState.Resolved, internalPage: String?) -> Bool {
        guard case .page(_, let tab) = resolved else { return false }
        return internalPageKind(tab, page: internalPage) == phonePageKind
    }

    /// Whether `controller`'s focused tab is a phone tab (``isPhone(_:internalPage:)`` for the registry context).
    func focusesPhone(in controller: WindowController) -> Bool {
        Self.isPhone(controller.focus.state.resolved, internalPage: focusedInternalPage(in: controller))
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
        let page = focusedPage(in: controller)
        // Only a code editor page has key sequences; the editor pages' service is not made for others.
        let editor = page?.descriptor.id == Self.codeEditorPageID ? page : nil
        return Facts(hasMarkedText: (window.firstResponder as? any NSTextInputClient)?.hasMarkedText() == true,
                     terminalCopyMode: terminalCopyMode(in: controller),
                     terminalAlternateScreen: terminalAlternateScreen(in: controller), pageID: page?.descriptor.id,
                     markdownReadOnly: services?.viewers.markdownPages.showsReadOnly(focusedIn: controller) == true,
                     listFocus: focusedReadiness(in: controller)?.isListFocused == true,
                     pageEditableFocused: focusedReadiness(in: controller)?.isEditableFocused == true,
                     omnibarListOpen: focusedAddressBar(in: controller)?.isShowingSuggestions == true,
                     internalPage: focusedInternalPage(in: controller),
                     showsPageHistory: services?.locationTrail.pageHistory(in: controller) != nil,
                     topPage: controller.shownTopPage == .home ? "home" : nil,
                     pageKeySequencePending: editor.map { services?.viewers.editorPages.keySequencePending(on: $0) ?? false } ?? false,
                     textBoxFocused: window.firstResponder is TextBoxTextView,
                     sidebarMultiSelection: controller.sidebar.model.selection.count > 1,
                     fileExplorerFocused: FileExplorerService.hasKeyboard(window),
                     workspacesAsTabs: SidebarTunables.workspacesAsTabsOn,
                     pageReportsUnhandledKeys: chromiumPageHasKeys(window, controller: controller))
    }

    /// The focused live Chromium tab's page window is `window`, the key window: the key reaches
    /// the page, and Chromium reports it if the page leaves it unhandled. While the shell window
    /// itself is key (a page the model names but Chromium has not been handed the keyboard), the
    /// key would reach no page, so cmux runs its action first as before.
    private func chromiumPageHasKeys(_ window: NSWindow, controller: WindowController) -> Bool {
        guard case .browserPage = controller.focus.state.resolved, let pane = controller.focus.state.resolved.pane,
              case .browser(let entry)? = controller.content?.paneController(key: pane)?.currentContent,
              let tab = entry.tab as? CEFTab else { return false }
        return tab.isPageWindow(window)
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
        // A top page (TopPages: Settings, App Store, ...) fills the content area with no pane:
        // its page has the keyboard when the window's first responder is inside it.
        if let route = controller.shownTopPage, case .page = route,
           let view = controller.topPages.views[route] as? InternalPageView,
           let responder = controller.window?.firstResponder as? NSView, responder.isDescendant(of: view) {
            return view.content as? PageWebView
        }
        var modelPage: PageWebView?
        if case .page(_, _) = controller.focus.state.resolved, let pane = controller.focus.state.resolved.pane,
           case .page(let view)? = controller.content?.paneController(key: pane)?.currentContent {
            modelPage = view.content as? PageWebView
        }
        return Self.keyPage(modelPage: modelPage, in: controller.window)
    }

    /// The page that gets the window's keys: the code editor page holding the keys
    /// (``codeEditorHoldingKeys(in:)``), else the page the focus model names (`modelPage`). AppKit
    /// sends the keys to the first responder, so the editor wins even while the model still names
    /// another pane's page (Shift-Cmd-L opened a browser tab from a Markdown tab's context).
    @MainActor static func keyPage(modelPage: PageWebView?, in window: NSWindow?) -> PageWebView? {
        codeEditorHoldingKeys(in: window) ?? modelPage
    }

    /// The code editor page whose web view is the window's first responder, also while the focus
    /// model names something else (a file opened by a script or an agent, or a click the model
    /// has not settled yet). AppKit sends the keys to the first responder, so the editor's context
    /// (`codeEditorFocused`) follows it: without it Shift-Cmd-L opened a browser tab instead of
    /// selecting every occurrence. Only the code editor: other pages keep the model's answer.
    @MainActor static func codeEditorHoldingKeys(in window: NSWindow?) -> PageWebView? {
        var view = window?.firstResponder as? NSView
        while let current = view {
            if let page = current as? PageWebView { return page.descriptor.id == codeEditorPageID ? page : nil }
            view = current.superview
        }
        return nil
    }

    private func terminalCopyMode(in controller: WindowController) -> Bool {
        guard case .terminal(let pane, _) = controller.focus.state.resolved,
              case .terminal(let entry)? = controller.content?.paneController(key: pane)?.currentContent else { return false }
        return entry.session.surfaceView.isCopyModeActive
    }

    private func terminalAlternateScreen(in controller: WindowController) -> Bool {
        guard case .terminal(let pane, _) = controller.focus.state.resolved,
              case .terminal(let entry)? = controller.content?.paneController(key: pane)?.currentContent else { return false }
        return entry.session.surfaceView.isAlternateScreen
    }
}
