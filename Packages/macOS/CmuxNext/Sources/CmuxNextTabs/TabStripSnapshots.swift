import CoreGraphics

// What the strip's observation loops compare between updates.
struct TabStripTokenSnapshot: Equatable, Sendable {
    var metrics: TabStripMetrics
    var titleFont: CGFloat
}

/// Model fields whose change triggers a sync.
struct TabStripModelSnapshot: Sendable {
    var tabs: [TabItem]
    var groups: [TabGroupItem]
    var selectedID: TabID?
    var style: TabStripStyle
    var showsNewTabButton: Bool
}
