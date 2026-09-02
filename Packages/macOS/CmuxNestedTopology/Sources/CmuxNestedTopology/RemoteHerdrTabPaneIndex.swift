/// Bidirectional Herdr pane ↔ host tab map used by Bonsplit leaf updates.
///
/// Removing a leaf must drop both directions. The inverse entry is stale if
/// `paneIdByTabId` still points at a pane that is gone.
public struct RemoteHerdrTabPaneIndex<TabID: Hashable & Sendable>: Sendable {
    /// Pane id → host tab id.
    public private(set) var tabIdByPaneId: [String: TabID]
    /// Host tab id → pane id.
    public private(set) var paneIdByTabId: [TabID: String]

    /// Empty maps.
    public init() {
        tabIdByPaneId = [:]
        paneIdByTabId = [:]
    }

    /// Seed from existing host dictionaries.
    ///
    /// - Parameter tabIdByPaneId: Forward map.
    /// - Parameter paneIdByTabId: Inverse map.
    public init(tabIdByPaneId: [String: TabID], paneIdByTabId: [TabID: String]) {
        self.tabIdByPaneId = tabIdByPaneId
        self.paneIdByTabId = paneIdByTabId
    }

    /// Record a live leaf.
    ///
    /// - Parameter paneID: Herdr pane id.
    /// - Parameter tabID: Host tab id for that leaf.
    public mutating func bind(paneID: String, tabID: TabID) {
        if let previousTab = tabIdByPaneId[paneID], previousTab != tabID,
           paneIdByTabId[previousTab] == paneID {
            paneIdByTabId.removeValue(forKey: previousTab)
        }
        if let previousPane = paneIdByTabId[tabID], previousPane != paneID {
            tabIdByPaneId.removeValue(forKey: previousPane)
        }
        tabIdByPaneId[paneID] = tabID
        paneIdByTabId[tabID] = paneID
    }

    /// Remove a leaf. Returns the captured tab id, if any.
    ///
    /// - Parameter paneID: Herdr pane id that closed.
    /// - Returns: The tab that owned the leaf, or `nil` if unknown.
    @discardableResult
    public mutating func removeLeaf(paneID: String) -> TabID? {
        let tabID = tabIdByPaneId[paneID]
        tabIdByPaneId.removeValue(forKey: paneID)
        if let tabID, paneIdByTabId[tabID] == paneID {
            paneIdByTabId.removeValue(forKey: tabID)
        }
        return tabID
    }
}
