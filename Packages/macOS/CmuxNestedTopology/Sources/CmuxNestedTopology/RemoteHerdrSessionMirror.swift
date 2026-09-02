/// Session-level tab set reconcile (tmux ``RemoteTmuxSessionMirror`` analogue).
public struct RemoteHerdrSessionReconcile: Hashable, Sendable {
    /// Tabs that need a new cmux tab / window mirror.
    public var createdTabIDs: [String]
    /// Tabs whose cmux tabs must close.
    public var closedTabIDs: [String]
    /// Tabs that already have a mirror.
    public var keptTabIDs: [String]
    /// Desired cmux tab order (Herdr tab numbers).
    public var orderedTabIDs: [String]
    /// Whether order differs from the previous order among kept+created tabs.
    public var orderChanged: Bool

    public init(
        createdTabIDs: [String] = [],
        closedTabIDs: [String] = [],
        keptTabIDs: [String] = [],
        orderedTabIDs: [String] = [],
        orderChanged: Bool = false
    ) {
        self.createdTabIDs = createdTabIDs
        self.closedTabIDs = closedTabIDs
        self.keptTabIDs = keptTabIDs
        self.orderedTabIDs = orderedTabIDs
        self.orderChanged = orderChanged
    }
}

/// Reconciles the set of Herdr tabs into cmux tabs.
public enum RemoteHerdrSessionMirror {
    /// Diffs desired windows against previously mirrored tab ids.
    public static func reconcile(
        windows: [RemoteHerdrWindow],
        previousTabIDs: [String]
    ) -> RemoteHerdrSessionReconcile {
        let ordered = windows.sorted { lhs, rhs in
            if lhs.orderIndex != rhs.orderIndex {
                return lhs.orderIndex < rhs.orderIndex
            }
            return lhs.tabID < rhs.tabID
        }.map(\.tabID)
        let desired = Set(ordered)
        let previous = previousTabIDs
        let previousSet = Set(previous)
        let created = ordered.filter { !previousSet.contains($0) }
        let closed = previous.filter { !desired.contains($0) }
        let kept = ordered.filter { previousSet.contains($0) }
        let previousLiveOrder = previous.filter { desired.contains($0) }
        let keptInDesiredOrder = ordered.filter { previousSet.contains($0) }
        return RemoteHerdrSessionReconcile(
            createdTabIDs: created,
            closedTabIDs: closed,
            keptTabIDs: kept,
            orderedTabIDs: ordered,
            orderChanged: previousLiveOrder != keptInDesiredOrder
        )
    }

    /// Builds windows from nested snapshot panes grouped by tab, plus optional layouts.
    public static func windows(
        from snapshot: NestedTopologySnapshot,
        layouts: [String: RemoteHerdrLayoutNode] = [:],
        zoomedPaneIDs: Set<String> = []
    ) -> [RemoteHerdrWindow] {
        let panesByTab = Dictionary(grouping: snapshot.panes, by: \.tabID)
        return snapshot.tabs.compactMap { tab in
            let panes = (panesByTab[tab.id] ?? []).sorted { lhs, rhs in
                    if lhs.orderIndex != rhs.orderIndex {
                        return lhs.orderIndex < rhs.orderIndex
                    }
                    return lhs.id.rawID < rhs.id.rawID
                }
            guard let layout = layouts[tab.id.rawID] ?? Self.fallbackLayout(paneIDs: panes.map(\.id.rawID))
            else {
                return nil
            }
            let zoomedID = panes.map(\.id.rawID).first { zoomedPaneIDs.contains($0) }
            let visible: RemoteHerdrLayoutNode?
            if let zoomedID, let leaf = layout.firstLeaf(withPaneID: zoomedID) {
                visible = leaf
            } else {
                visible = nil
            }
            let focused = snapshot.focus.paneID?.rawID
            let active = panes.map(\.id.rawID).first { $0 == focused }
            return RemoteHerdrWindow(
                tabID: tab.id.rawID,
                title: tab.displayTitle,
                orderIndex: tab.orderIndex,
                layout: layout,
                visibleLayout: visible,
                zoomed: zoomedID != nil,
                activePaneID: active
            )
        }
    }

    /// Stack remaining panes vertically when Herdr did not publish a tree.
    /// Returns `nil` when there are no panes (never synthesizes an empty pane id).
    public static func fallbackLayout(paneIDs: [String]) -> RemoteHerdrLayoutNode? {
        guard let first = paneIDs.first else {
            return nil
        }
        if paneIDs.count == 1 {
            return RemoteHerdrLayoutNode(
                width: 80,
                height: 24,
                x: 0,
                y: 0,
                content: .pane(first)
            )
        }
        let children = paneIDs.enumerated().map { index, paneID in
            RemoteHerdrLayoutNode(
                width: 80,
                height: 12,
                x: 0,
                y: index * 12,
                content: .pane(paneID)
            )
        }
        return RemoteHerdrLayoutNode(
            width: 80,
            height: 24,
            x: 0,
            y: 0,
            content: .vertical(children)
        )
    }
}
