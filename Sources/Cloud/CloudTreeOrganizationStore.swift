import Foundation

/// Local presentation preferences, keyed by placement identity rather than row index.
/// Missing rows retain their slots so a disconnected machine can return in place.
@MainActor
final class CloudTreeOrganizationStore {
    private struct State: Codable {
        var orders: [String: [String]] = [:]
        var pins: Set<String> = []
    }

    private static let key = "cloudTree.organization.v1"
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

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func arranged(_ nodes: [CloudTreeNode]) -> [CloudTreeNode] {
        arrange(nodes, parentID: "", state: state)
    }

    private func arrange(_ nodes: [CloudTreeNode], parentID: String, state: State) -> [CloudTreeNode] {
        let order = state.orders[parentID] ?? []
        let ranks = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        return nodes.enumerated().sorted { lhs, rhs in
            let lp = state.pins.contains(lhs.element.id)
            let rp = state.pins.contains(rhs.element.id)
            if lp != rp { return lp }
            let li = ranks[lhs.element.id] ?? (order.count + lhs.offset)
            let ri = ranks[rhs.element.id] ?? (order.count + rhs.offset)
            return li < ri
        }.map { _, node in
            node.organized(
                children: arrange(node.children, parentID: node.id, state: state),
                isPinned: state.pins.contains(node.id)
            )
        }
    }

    func canMove(_ id: String, by delta: Int, in nodes: [CloudTreeNode]) -> Bool {
        guard let context = siblings(of: id, in: arranged(nodes)),
              let index = context.nodes.firstIndex(where: { $0.id == id }) else { return false }
        let destination = index + delta
        return context.nodes.indices.contains(destination)
            && context.nodes[destination].canOrganize
            && context.nodes[index].canOrganize
            && context.nodes[index].isPinned == context.nodes[destination].isPinned
    }

    @discardableResult
    func move(_ id: String, by delta: Int, in nodes: [CloudTreeNode]) -> Bool {
        guard canMove(id, by: delta, in: nodes),
              let context = siblings(of: id, in: arranged(nodes)),
              let index = context.nodes.firstIndex(where: { $0.id == id }) else { return false }
        return move(id, parentID: context.parentID, to: index + delta, in: nodes)
    }

    /// Moves within a folder and pin tier. It never reparents a remote placement.
    @discardableResult
    func move(_ id: String, parentID: String, to index: Int, in nodes: [CloudTreeNode]) -> Bool {
        guard let context = siblings(of: id, in: arranged(nodes)), context.parentID == parentID,
              let source = context.nodes.firstIndex(where: { $0.id == id }),
              context.nodes[source].canOrganize else { return false }
        var siblings = context.nodes
        let node = siblings.remove(at: source)
        let pinnedCount = siblings.filter(\.isPinned).count
        let lower = node.isPinned ? 0 : pinnedCount
        let upper = node.isPinned ? pinnedCount : siblings.count
        let destination = max(lower, min(index, upper))
        siblings.insert(node, at: destination)
        guard siblings.map(\.id) != context.nodes.map(\.id) else { return false }
        saveOrder(siblings.map(\.id), parentID: parentID)
        return true
    }

    func togglePin(_ id: String, in nodes: [CloudTreeNode]) {
        guard let context = siblings(of: id, in: arranged(nodes)),
              let node = context.nodes.first(where: { $0.id == id }), node.canOrganize else { return }
        var saved = state
        if node.isPinned { saved.pins.remove(id) } else { saved.pins.insert(id) }
        state = saved
        // Pin at the end of the pinned tier; unpin at the start of the ordinary tier.
        let peers = context.nodes.filter { $0.id != id }
        let boundary = peers.filter(\.isPinned).count
        var ids = peers.map(\.id)
        ids.insert(id, at: boundary)
        saveOrder(ids, parentID: context.parentID)
    }

    func siblings(of id: String, in nodes: [CloudTreeNode], parentID: String = "") -> (parentID: String, nodes: [CloudTreeNode])? {
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
