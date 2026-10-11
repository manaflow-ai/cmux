import AppKit

extension WorkspaceRowView {
    /// Routes AXPress through the sidebar's shared workspace selection action.
    override func accessibilityPerformPress() -> Bool {
        guard !isShowingPlaceholder, let onSelect else { return false }
        onSelect()
        return true
    }

    /// Show Tabs or Hide Tabs on every row with tabs: the chevron shows only
    /// on hover or selection (cx-fo2t), and a hidden button leaves the
    /// accessibility tree.
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let disclosure, disclosure != .empty, let onToggleTabs, !isShowingPlaceholder else { return super.accessibilityCustomActions() }
        let name = disclosure == .expanded ? Strings.hideTabs : Strings.showTabs
        return (super.accessibilityCustomActions() ?? []) + [NSAccessibilityCustomAction(name: name) { onToggleTabs(); return true }]
    }
}
