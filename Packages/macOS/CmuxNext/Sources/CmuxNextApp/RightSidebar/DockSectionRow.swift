import CmuxNextLayout

/// One docked column of the shown screen in the Dock section (a value snapshot).
nonisolated struct DockSectionRow: Identifiable, Hashable, Sendable {
    /// The column's id (`column.undock`'s target).
    let id: String
    let edge: DockEdge
    /// The column's first pane (the row's click focuses it).
    let pane: String
    /// Its selected tab's title.
    let title: String

    /// The edge's SF Symbol.
    var symbol: String {
        switch edge {
        case .left: "sidebar.left"
        case .right: "sidebar.right"
        case .top: "rectangle.tophalf.inset.filled"
        case .bottom: "rectangle.bottomhalf.inset.filled"
        }
    }
}
