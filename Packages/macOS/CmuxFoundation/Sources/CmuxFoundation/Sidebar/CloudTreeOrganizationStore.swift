public import Foundation

/// Local presentation preferences, keyed by placement identity rather than row index.
/// Missing rows retain their slots so a disconnected machine can return in place.
@MainActor
public final class CloudTreeOrganizationStore<Node: CloudTreeOrganizationNode> {
    private struct State: Codable {
        var orders: [String: [String]] = [:]
        var pins: Set<String> = []
    }

    private static var key: String { "cloudTree.organization.v1" }
    private let defaults: UserDefaults
    private var state: State {
        get {
            guard let data = defaults.data(forKey: Self.key),
                  let saved = try? JSONDecoder().decode(State.self, from: data) else { return State() }
            return saved
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Self.key)
        }
    }

    /// Creates a store using an explicitly supplied preferences domain.
    /// - Parameter defaults: The application or isolated test preferences domain.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Returns a new tree in saved order, retaining node identity and payloads.
    /// - Parameter nodes: The current authoritative catalog tree.
    /// - Returns: Fixed rows, pinned rows, and ordinary rows within each parent.
    public func arranged(_ nodes: [Node]) -> [Node] {
        arrange(nodes, parentID: "", state: state)
    }

    private func arrange(_ nodes: [Node], parentID: String, state: State) -> [Node] {
        let order = state.orders[parentID] ?? []
        var remaining = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var fixed: [Node] = []
        var pinned: [Node] = []
        var leading: [Node] = []
        var ordinary: [Node] = []
        for node in nodes where !node.canOrganize {
            fixed.append(node)
            remaining.removeValue(forKey: node.id)
        }
        for id in order {
            guard let node = remaining.removeValue(forKey: id) else { continue }
            if state.pins.contains(id) { pinned.append(node) } else { ordinary.append(node) }
        }
        for node in nodes {
            guard remaining.removeValue(forKey: node.id) != nil else { continue }
            if state.pins.contains(node.id) { pinned.append(node) }
            else if node.prefersLeadingPlacement { leading.append(node) }
            else { ordinary.append(node) }
        }
        return (fixed + pinned + leading + ordinary).map { node in
            node.organized(
                children: arrange(node.children, parentID: node.id, state: state),
                isPinned: node.canOrganize && state.pins.contains(node.id)
            )
        }
    }

    /// Checks whether a relative move stays within the same folder and pin tier.
    /// - Parameters:
    ///   - id: The stable placement identifier.
    ///   - delta: The relative row offset.
    ///   - nodes: The current tree.
    ///   - alreadyArranged: Whether the caller supplies the displayed arrangement.
    /// - Returns: Whether the destination is an organizable peer in the same tier.
    public func canMove(_ id: String, by delta: Int, in nodes: [Node], alreadyArranged: Bool = false) -> Bool {
        guard let context = siblings(of: id, in: alreadyArranged ? nodes : arranged(nodes)),
              let index = context.nodes.firstIndex(where: { $0.id == id }) else { return false }
        let destination = index + delta
        return context.nodes.indices.contains(destination)
            && context.nodes[destination].canOrganize
            && context.nodes[index].canOrganize
            && context.nodes[index].isPinned == context.nodes[destination].isPinned
    }

    /// Persists a relative move within the current folder and pin tier.
    /// - Parameters:
    ///   - id: The stable placement identifier.
    ///   - delta: The relative row offset.
    ///   - nodes: The current catalog tree.
    /// - Returns: Whether the saved order changed.
    @discardableResult
    public func move(_ id: String, by delta: Int, in nodes: [Node]) -> Bool {
        guard canMove(id, by: delta, in: nodes),
              let context = siblings(of: id, in: arranged(nodes)),
              let index = context.nodes.firstIndex(where: { $0.id == id }) else { return false }
        return move(id, parentID: context.parentID, to: index + delta, in: nodes)
    }

    /// Persists a final sibling index, clamped to the node’s pin tier.
    /// - Parameters:
    ///   - id: The stable placement identifier.
    ///   - parentID: The existing parent identifier; empty for roots.
    ///   - index: The final index after removing the source.
    ///   - nodes: The current catalog tree.
    /// - Returns: Whether the saved order changed.
    @discardableResult
    public func move(_ id: String, parentID: String, to index: Int, in nodes: [Node]) -> Bool {
        guard let context = siblings(of: id, in: arranged(nodes)), context.parentID == parentID,
              let source = context.nodes.firstIndex(where: { $0.id == id }),
              context.nodes[source].canOrganize else { return false }
        var siblings = context.nodes
        let node = siblings.remove(at: source)
        let pinnedCount = siblings.filter(\.isPinned).count
        let fixedCount = siblings.prefix { !$0.canOrganize }.count
        let lower = node.isPinned ? fixedCount : fixedCount + pinnedCount
        let upper = node.isPinned ? fixedCount + pinnedCount : siblings.count
        let destination = max(lower, min(index, upper))
        siblings.insert(node, at: destination)
        guard siblings.map(\.id) != context.nodes.map(\.id) else { return false }
        saveOrder(siblings.map(\.id), parentID: parentID)
        return true
    }

    /// Pins at the end of the pinned tier or unpins at the start of ordinary rows.
    /// - Parameters:
    ///   - id: The stable placement identifier.
    ///   - nodes: The current catalog tree.
    public func togglePin(_ id: String, in nodes: [Node]) {
        guard let context = siblings(of: id, in: arranged(nodes)),
              let node = context.nodes.first(where: { $0.id == id }), node.canOrganize else { return }
        var saved = state
        if node.isPinned { saved.pins.remove(id) } else { saved.pins.insert(id) }
        state = saved
        // Pin at the end of the pinned tier; unpin at the start of the ordinary tier.
        let peers = context.nodes.filter { $0.id != id }
        let boundary = peers.prefix { !$0.canOrganize }.count + peers.filter(\.isPinned).count
        var ids = peers.map(\.id)
        ids.insert(id, at: boundary)
        saveOrder(ids, parentID: context.parentID)
    }

    /// Finds a node’s sibling collection without changing its arrangement.
    /// - Parameters:
    ///   - id: The stable placement identifier to find.
    ///   - nodes: The tree to search.
    ///   - parentID: The identifier of the supplied tree’s parent; empty for roots.
    /// - Returns: The parent and siblings, or nil when the node is absent.
    public func siblings(of id: String, in nodes: [Node], parentID: String = "") -> (parentID: String, nodes: [Node])? {
        if nodes.contains(where: { $0.id == id }) { return (parentID, nodes) }
        for node in nodes {
            if let result = siblings(of: id, in: node.children, parentID: node.id) { return result }
        }
        return nil
    }

    private func saveOrder(_ visible: [String], parentID: String) {
        var saved = state
        let visibleSet = Set(visible)
        var remaining = visible.makeIterator()
        // Replace live slots, retaining absent identities between those slots.
        var merged = (saved.orders[parentID] ?? []).map { id in
            visibleSet.contains(id) ? (remaining.next() ?? id) : id
        }
        while let id = remaining.next() { merged.append(id) }
        saved.orders[parentID] = merged
        state = saved
    }
}
