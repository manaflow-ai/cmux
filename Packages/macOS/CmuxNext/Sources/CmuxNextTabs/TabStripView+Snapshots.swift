import CoreGraphics

// What the strip's observation loops compare between updates.
extension TabStripView {
    /// Design tokens the strip re-applies on change.
    struct TokenSnapshot: Equatable, Sendable {
        var metrics: TabStripMetrics
        var titleFont: CGFloat
    }

    /// Model fields whose change triggers a sync.
    struct ModelSnapshot: Sendable {
        var tabs: [TabItem]
        var groups: [TabGroupItem]
        var selectedID: TabID?
        var style: TabStripStyle
        var showsNewTabButton: Bool
        var trailingButtons: [TabStripButton]
    }
}
