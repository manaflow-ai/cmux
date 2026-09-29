public import CmuxNextDaemon
public import CmuxNextLayout

/// Translates the layout engine's durable string ids back to the daemon's
/// generation-scoped numeric handles for commands. Rebuilt on every mapping,
/// so handles refreshed by a resync are always current.
public struct LayoutHandleMap: Sendable, Equatable {
    public var panes: [LayoutPaneID: DaemonPaneID] = [:]
    public var paneIDs: [DaemonPaneID: LayoutPaneID] = [:]
    public var splits: [LayoutSplitID: DaemonSplitID] = [:]
    public var columns: [LayoutColumnID: DaemonColumnID] = [:]
    public var screens: [LayoutScreenID: DaemonScreenID] = [:]

    public init() {}

    mutating func addPane(_ id: LayoutPaneID, handle: DaemonPaneID) {
        panes[id] = handle
        paneIDs[handle] = id
    }

    /// Layout id of a split: `split:<n>`, or anchored on its first pane for
    /// servers older than protocol v8 that omit split ids.
    static func splitID(_ handle: DaemonSplitID?, firstPane: LayoutPaneID?) -> LayoutSplitID {
        if let handle { return LayoutSplitID("split:\(handle.rawValue)") }
        return LayoutSplitID("split@\(firstPane?.rawValue ?? "none")")
    }

    static func columnID(_ handle: DaemonColumnID) -> LayoutColumnID {
        LayoutColumnID("column:\(handle.rawValue)")
    }
}
