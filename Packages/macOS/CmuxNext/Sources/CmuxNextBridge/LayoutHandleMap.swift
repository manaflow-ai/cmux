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
    public var rows: [LayoutRowID: DaemonRowID] = [:]
    public var screens: [LayoutScreenID: DaemonScreenID] = [:]

    public init() {}

    /// Whether `intent`'s command can go to the daemon now (`LayoutModel.sendsNow`): its split has a handle, its column's
    /// pane a handle of a pane the daemon made (a stand-in's names nothing there).
    public func sendsNow(_ intent: LayoutIntent) -> Bool {
        switch intent {
        case let .setSplitRatio(split, _, _, _): splits[split] != nil
        case let .setColumnWidth(_, anyPane, _, _, _): panes[anyPane].map { !ProvisionalPane.isStandIn($0) } ?? false
        default: true
        }
    }

    /// The daemon's form of an intent's size values (`LayoutIntent.sizes`), in their order; nil when one of them
    /// cannot go to the daemon now (the rule of `sendsNow`), so that none of them goes.
    public func sizeValues(_ values: [LayoutIntent.SizeValue]) -> [SetLayoutSizesRequest.Value]? {
        var wire: [SetLayoutSizesRequest.Value] = []
        for value in values {
            switch value {
            case let .ratio(split, ratio):
                guard let handle = splits[split] else { return nil }
                wire.append(.ratio(handle, ratio))
            case let .width(_, anyPane, width):
                guard let handle = panes[anyPane], !ProvisionalPane.isStandIn(handle) else { return nil }
                wire.append(.width(pane: handle, width))
            }
        }
        return wire
    }

    mutating func addPane(_ id: LayoutPaneID, handle: DaemonPaneID) {
        panes[id] = handle
        paneIDs[handle] = id
    }

    /// Layout id of a split: `split:<n>`, or anchored on its first pane for
    /// servers older than protocol v8 that omit split ids.
    /// The public id when the daemon names the split (`split-client-split-id-v1`), else its handle.
    static func splitID(_ resourceID: CmuxNextDaemon.ResourceID?, handle: DaemonSplitID?, firstPane: LayoutPaneID?) -> LayoutSplitID {
        if let resourceID { return LayoutSplitID("split:\(resourceID.rawValue)") }
        if let handle { return LayoutSplitID("split:\(handle.rawValue)") }
        return LayoutSplitID("split@\(firstPane?.rawValue ?? "none")")
    }

    static func columnID(_ handle: DaemonColumnID) -> LayoutColumnID {
        LayoutColumnID("column:\(handle.rawValue)")
    }

    static func rowID(_ handle: DaemonRowID) -> LayoutRowID {
        LayoutRowID("row:\(handle.rawValue)")
    }
}
