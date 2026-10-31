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
        var zoomsSelected = false

        @MainActor init(_ model: TabStripModel) {
            self.init(tabs: model.tabs, groups: model.groups, selectedID: model.selectedID,
                      style: model.style, showsNewTabButton: model.showsNewTabButton)
            multiSelection = model.multiSelection
            showsSelectedFullWidth = model.showsSelectedFullWidth
            zoomsSelected = model.zoomsSelected
        }

        init(tabs: [TabItem], groups: [TabGroupItem], selectedID: TabID?, style: TabStripStyle, showsNewTabButton: Bool) {
            self.tabs = tabs
            self.groups = groups
            self.selectedID = selectedID
            self.style = style
            self.showsNewTabButton = showsNewTabButton
        }

        /// The same strip with another tab selected (a tab switch), other tabs multi-selected or
        /// the pane zoomed or not (the selected tab's zoom indicator). Never in Full Width Tab mode,
        /// where the selection decides the geometry.
        func differsOnlyInSelection(from other: ModelSnapshot) -> Bool {
            !showsSelectedFullWidth && showsSelectedFullWidth == other.showsSelectedFullWidth
                && (selectedID != other.selectedID || multiSelection != other.multiSelection || zoomsSelected != other.zoomsSelected)
                && tabs == other.tabs && groups == other.groups
                && style == other.style && showsNewTabButton == other.showsNewTabButton
        }
    }
}
