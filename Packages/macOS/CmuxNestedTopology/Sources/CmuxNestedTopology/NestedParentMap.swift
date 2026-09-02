/// Stable child→parent map used by two-pass rendering.
///
/// Render paths consult this map instead of re-inferring parents every tick.
public struct NestedParentMap: Hashable, Codable, Sendable {
    private var parentsByChild: [NestedNodeID: NestedNodeID]

    /// Creates an empty parent map.
    public init() {
        self.parentsByChild = [:]
    }

    /// Creates a parent map from an explicit dictionary.
    public init(parentsByChild: [NestedNodeID: NestedNodeID]) {
        self.parentsByChild = parentsByChild
    }

    /// Number of recorded parent edges.
    public var count: Int { parentsByChild.count }

    /// Records or replaces the parent for a child node.
    public mutating func setParent(of child: NestedNodeID, to parent: NestedNodeID) {
        parentsByChild[child] = parent
    }

    /// Returns the recorded parent for a child, if any.
    public func parent(of child: NestedNodeID) -> NestedNodeID? {
        parentsByChild[child]
    }

    /// Removes one child edge.
    public mutating func remove(_ child: NestedNodeID) {
        parentsByChild.removeValue(forKey: child)
    }

    /// Removes `root` and every descendant reachable through this map.
    public mutating func removeSubtree(rootedAt root: NestedNodeID) {
        var childrenByParent: [NestedNodeID: [NestedNodeID]] = [:]
        for (child, parent) in parentsByChild {
            childrenByParent[parent, default: []].append(child)
        }

        var toRemove: Set<NestedNodeID> = [root]
        var pending = [root]
        while let parent = pending.popLast() {
            for child in childrenByParent[parent, default: []]
            where toRemove.insert(child).inserted {
                pending.append(child)
            }
        }

        parentsByChild = parentsByChild.filter { !toRemove.contains($0.key) }
    }

    /// Rebuilds the map from a validated snapshot's authoritative parent fields.
    public mutating func replace(with snapshot: NestedTopologySnapshot) {
        var next: [NestedNodeID: NestedNodeID] = [:]
        for tab in snapshot.tabs {
            next[tab.id] = tab.workspaceID
        }
        for pane in snapshot.panes {
            next[pane.id] = pane.tabID
        }
        for agent in snapshot.agents {
            next[agent.id] = agent.paneID
        }
        parentsByChild = next
    }

    /// Applies an ordered event batch to the parent map without re-inferring from titles.
    ///
    /// Reshuffled batches that describe the same final parentage converge to the same map.
    public mutating func apply(events: [NestedTopologyEvent]) {
        for event in events {
            switch event {
            case .replaceSnapshot(let snapshot):
                replace(with: snapshot)
            case .tabUpserted(let tab):
                setParent(of: tab.id, to: tab.workspaceID)
            case .paneUpserted(let pane):
                setParent(of: pane.id, to: pane.tabID)
            case .agentUpserted(let agent):
                setParent(of: agent.id, to: agent.paneID)
            case .workspaceClosed(let id), .tabClosed(let id), .paneClosed(let id):
                removeSubtree(rootedAt: id)
            case .agentClosed(let id):
                remove(id)
            case .workspaceUpserted, .focusChanged, .titleUpdated, .agentStatusUpdated:
                break
            }
        }
    }

    /// Deterministic edge list for tests and diffs.
    public var sortedEdges: [(child: NestedNodeID, parent: NestedNodeID)] {
        parentsByChild.keys.sorted().compactMap { child in
            guard let parent = parentsByChild[child] else { return nil }
            return (child: child, parent: parent)
        }
    }
}
