import CoreGraphics

// What the strip's observation loops compare between updates.
extension TabStripView {
    /// Design tokens the strip re-applies on change.
    struct TokenSnapshot: Equatable, Sendable {
        var metrics: TabStripMetrics
        var titleFont: CGFloat
    }

    /// Model fields whose change triggers a sync. Equal arrays that share
    /// storage compare in O(1), so the echo of an applied model costs nothing.
    struct ModelSnapshot: Equatable, Sendable {
        var tabs: [TabItem]
        var groups: [TabGroupItem]
        var selectedID: TabID?
        var multiSelection = TabMultiSelection()
        var style: TabStripStyle
        var showsNewTabButton: Bool
        var showsSelectedFullWidth = false

        @MainActor init(_ model: TabStripModel) {
            self.init(tabs: model.tabs, groups: model.groups, selectedID: model.selectedID,
                      style: model.style, showsNewTabButton: model.showsNewTabButton)
            multiSelection = model.multiSelection
            showsSelectedFullWidth = model.showsSelectedFullWidth
        }

        init(tabs: [TabItem], groups: [TabGroupItem], selectedID: TabID?, style: TabStripStyle, showsNewTabButton: Bool) {
            self.tabs = tabs
            self.groups = groups
            self.selectedID = selectedID
            self.style = style
            self.showsNewTabButton = showsNewTabButton
        }

        /// The same strip with another tab selected (a tab switch) or other tabs multi-selected.
        /// Never in Full Width Tab mode, where the selection decides the geometry.
        func differsOnlyInSelection(from other: ModelSnapshot) -> Bool {
            !showsSelectedFullWidth && showsSelectedFullWidth == other.showsSelectedFullWidth
                && (selectedID != other.selectedID || multiSelection != other.multiSelection) && tabs == other.tabs && groups == other.groups
                && style == other.style && showsNewTabButton == other.showsNewTabButton
        }

        /// The same strip, laid out the same, with only what tabs draw changed (a title, an icon, a status, a
        /// spinner, presence): no tab came, went or moved, none changed its pin or group, and the groups,
        /// selection and style are the same (`TabLayoutEngine` reads nothing else; a tab's width never
        /// follows its title).
        func differsOnlyInTabContent(from other: ModelSnapshot) -> Bool {
            tabs != other.tabs && tabs.count == other.tabs.count && groups == other.groups && selectedID == other.selectedID
                && multiSelection == other.multiSelection && style == other.style && showsNewTabButton == other.showsNewTabButton
                && showsSelectedFullWidth == other.showsSelectedFullWidth
                && zip(tabs, other.tabs).allSatisfy { $0.id == $1.id && $0.isPinned == $1.isPinned && $0.groupID == $1.groupID }
        }
    }
}
