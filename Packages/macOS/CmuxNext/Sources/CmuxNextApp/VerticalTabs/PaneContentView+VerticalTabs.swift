import AppKit
import CmuxNextDesign
import CmuxNextTabs

/// How a pane shows vertical tabs (``WorkspaceVerticalTabs``): collapsed to icons, and whether a
/// collapsed list widens on hover (`tabs.verticalTabsExpandOnHover`).
struct PaneVerticalTabs: Equatable {
    var collapsed = false
    var expandsOnHover = true

    /// How a pane of workspace `id` shows vertical tabs; nil (the strip) unless the workspace shows them.
    /// A pane that shows no strip (`hidden`: Hide Tab Bar, an app, the Home dock) shows no list either.
    @MainActor static func shown(in id: String?, unless hidden: Bool, store: WorkspaceVerticalTabs = .shared,
                                 design: DesignSettings = .shared) -> PaneVerticalTabs? {
        guard !hidden, store.isVertical(id, allWorkspaces: design.verticalTabs) else { return nil }
        return PaneVerticalTabs(collapsed: store.isCollapsed, expandsOnHover: design.verticalTabsExpandOnHover)
    }
}

extension PaneContentView {
    /// The strip, or the vertical list in its place (Leo 2026-10-20): vertical tabs hide the strip.
    func showStrip(hidden: Bool, vertical: PaneVerticalTabs?) {
        let hides = hidden || vertical != nil
        if hidesStrip != hides { hidesStrip = hides }
        if verticalTabs != vertical { verticalTabs = vertical }
    }

    /// Shows, updates or hides the vertical list. The strip hides through `hidesStrip`
    /// (``PaneController/apply(_:force:)``), so the pane's header goes with it.
    func applyVerticalTabs() {
        guard let wanted = verticalTabs else {
            verticalList?.isHidden = true
            needsLayout = true
            return
        }
        let list = verticalList ?? makeVerticalList()
        list.isHidden = false
        if list.isCollapsed != wanted.collapsed { list.isCollapsed = wanted.collapsed }
        if list.expandsOnHover != wanted.expandsOnHover { list.expandsOnHover = wanted.expandsOnHover }
        needsLayout = true
    }

    private func makeVerticalList() -> VerticalTabListView {
        let list = VerticalTabListView(model: stripView.model)
        // The strip's providers, set by the pane before its first apply: one tab menu and one empty-area
        // menu for the strip and the list.
        list.contextMenuProvider = stripView.contextMenuProvider
        list.previewProvider = stripView.previewProvider
        list.onHoverExpansionChange = { [weak self] _ in self?.needsLayout = true }
        // Above the content: an expanded-on-hover list draws over the page beside it.
        addSubview(list, positioned: .above, relativeTo: contentHost)
        verticalList = list
        return list
    }

    /// Lays the list out on the pane's leading edge and returns the width it takes from the content
    /// (its resting width: a list expanded on hover draws over the content and moves nothing). A narrow
    /// pane gives the list at most half its width, so its content never shrinks to nothing.
    func layoutVerticalList() -> CGFloat {
        guard verticalTabs != nil, let list = verticalList, !list.isHidden else { return 0 }
        let reserved = min(list.reservedWidth, (bounds.width / 2).rounded(.down))
        let width = list.isHoverExpanded ? max(reserved, VerticalTabListView.expandedWidth) : reserved
        let frame = NSRect(x: 0, y: 0, width: min(width, bounds.width), height: bounds.height)
        if list.frame != frame { list.frame = frame }
        return reserved
    }
}
