/// The inputs a window's key facts are built from (``KeyContextStamp``): the focus, the first responder,
/// the top page, workspaces as tabs, and whether the sidebar selection is above one row. Flags that change
/// inside the objects a build found (a list taking focus in the page, copy mode) are not here: the key
/// router reads them from those objects on every key. Each input names its ``KeyContextInvalidation``.
public nonisolated struct KeyFactsStamp<Focus: Equatable, TopPage: Equatable>: KeyContextStamp {
    public var focus: Focus
    public var responder: ObjectIdentifier?
    public var topPage: TopPage?
    public var workspacesAsTabs: Bool
    public var sidebarMultiSelection: Bool

    public init(focus: Focus, responder: ObjectIdentifier?, topPage: TopPage?, workspacesAsTabs: Bool, sidebarMultiSelection: Bool) {
        self.focus = focus
        self.responder = responder
        self.topPage = topPage
        self.workspacesAsTabs = workspacesAsTabs
        self.sidebarMultiSelection = sidebarMultiSelection
    }

    public func invalidation(since earlier: KeyFactsStamp) -> KeyContextInvalidation {
        if focus != earlier.focus { return .focusTransition }
        if topPage != earlier.topPage { return .topPage }
        if responder != earlier.responder { return .firstResponder }
        if workspacesAsTabs != earlier.workspacesAsTabs { return .workspacesAsTabs }
        return .sidebarSelection
    }
}
