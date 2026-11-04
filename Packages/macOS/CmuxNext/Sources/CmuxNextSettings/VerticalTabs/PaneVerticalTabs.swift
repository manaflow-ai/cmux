public import CmuxNextDesign

/// How a pane shows vertical tabs (``WorkspaceVerticalTabs``): collapsed to icons, and whether a
/// collapsed list widens on hover (`tabs.verticalTabsExpandOnHover`).
public struct PaneVerticalTabs: Equatable {
    public var collapsed = false
    public var expandsOnHover = true

    public init(collapsed: Bool = false, expandsOnHover: Bool = true) {
        self.collapsed = collapsed
        self.expandsOnHover = expandsOnHover
    }

    /// How a pane of workspace `id` shows vertical tabs; nil (the strip) unless the workspace shows them.
    /// A pane that shows no strip (`hidden`: Hide Tab Bar, an app, the Home dock) shows no list either.
    @MainActor public static func shown(in id: String?, unless hidden: Bool, store: WorkspaceVerticalTabs,
                             design: DesignSettings = .shared) -> PaneVerticalTabs? {
        guard !hidden, store.isVertical(id, allWorkspaces: design.verticalTabs) else { return nil }
        return PaneVerticalTabs(collapsed: store.isCollapsed, expandsOnHover: design.verticalTabsExpandOnHover)
    }
}
