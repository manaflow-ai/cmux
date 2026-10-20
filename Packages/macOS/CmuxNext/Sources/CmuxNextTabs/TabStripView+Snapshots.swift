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
        var style: TabStripStyle
        var showsNewTabButton: Bool

        @MainActor init(_ model: TabStripModel) {
            self.init(tabs: model.tabs, groups: model.groups, selectedID: model.selectedID,
                      style: model.style, showsNewTabButton: model.showsNewTabButton)
        }

        init(tabs: [TabItem], groups: [TabGroupItem], selectedID: TabID?, style: TabStripStyle, showsNewTabButton: Bool) {
            self.tabs = tabs
            self.groups = groups
            self.selectedID = selectedID
            self.style = style
            self.showsNewTabButton = showsNewTabButton
        }

        /// The same strip with another tab selected (a tab switch).
        func differsOnlyInSelection(from other: ModelSnapshot) -> Bool {
            selectedID != other.selectedID && tabs == other.tabs && groups == other.groups
                && style == other.style && showsNewTabButton == other.showsNewTabButton
        }
    }
}
