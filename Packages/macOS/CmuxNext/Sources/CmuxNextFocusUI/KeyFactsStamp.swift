/// The inputs a window's key facts are built from (``KeyContextStamp``): the focus, the first responder,
/// the top page, workspaces as tabs, and the flags the key router reads from the objects its last build
/// found (the focused page's readiness, the address bar, the terminal, the sidebar, the markdown page).
/// Each input names its ``KeyContextInvalidation``.
public nonisolated struct KeyFactsStamp<Focus: Equatable, TopPage: Equatable>: KeyContextStamp {
    public var focus: Focus
    public var responder: ObjectIdentifier?
    public var topPage: TopPage?
    public var workspacesAsTabs: Bool
    public var listFocus: Bool
    public var pageEditableFocused: Bool
    public var omnibarListOpen: Bool
    public var terminalCopyMode: Bool
    public var sidebarMultiSelection: Bool
    public var markdownReadOnly: Bool

    public init(focus: Focus, responder: ObjectIdentifier?, topPage: TopPage?, workspacesAsTabs: Bool, listFocus: Bool,
                pageEditableFocused: Bool, omnibarListOpen: Bool, terminalCopyMode: Bool, sidebarMultiSelection: Bool,
                markdownReadOnly: Bool) {
        self.focus = focus
        self.responder = responder
        self.topPage = topPage
        self.workspacesAsTabs = workspacesAsTabs
        self.listFocus = listFocus
        self.pageEditableFocused = pageEditableFocused
        self.omnibarListOpen = omnibarListOpen
        self.terminalCopyMode = terminalCopyMode
        self.sidebarMultiSelection = sidebarMultiSelection
        self.markdownReadOnly = markdownReadOnly
    }

    public func invalidation(since earlier: KeyFactsStamp) -> KeyContextInvalidation {
        if focus != earlier.focus { return .focusTransition }
        if topPage != earlier.topPage { return .topPage }
        if responder != earlier.responder { return .firstResponder }
        if workspacesAsTabs != earlier.workspacesAsTabs { return .workspacesAsTabs }
        if listFocus != earlier.listFocus || pageEditableFocused != earlier.pageEditableFocused { return .pageInputReadiness }
        if omnibarListOpen != earlier.omnibarListOpen { return .suggestionList }
        if terminalCopyMode != earlier.terminalCopyMode { return .copyMode }
        if sidebarMultiSelection != earlier.sidebarMultiSelection { return .sidebarSelection }
        return .markdownReadOnly
    }
}
