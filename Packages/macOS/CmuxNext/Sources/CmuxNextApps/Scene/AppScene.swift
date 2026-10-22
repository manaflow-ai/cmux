/// A mounted contribution's scene graph: the pure reducer over scene ops.
/// The app VM owns the scene; this is the client's mirror (app-platform.md
/// section 7). Budgets match the runtime: 4096 nodes, depth 64. Ops that
/// would exceed a budget are refused and reported; the mirror stays valid.
public nonisolated struct AppScene: Sendable, Hashable {
    public static let maxNodes = 4096
    public static let maxDepth = 64

    public private(set) var nodes: [String: AppSceneNode] = [:]
    public private(set) var root: String?
    private var parent: [String: String] = [:]

    public init() {}

    public var count: Int { nodes.count }
    public subscript(_ id: String) -> AppSceneNode? { nodes[id] }

    /// Why an op was refused.
    public enum Issue: Sendable, Hashable {
        case nodeBudget
        case depthBudget(String)
        case duplicateID(String)
    }

    /// Applies a batch in order; returns the refused ops' issues.
    @discardableResult
    public mutating func apply(_ ops: [AppSceneOp]) -> [Issue] {
        var touched = Set<String>()
        return apply(ops, touched: &touched)
    }

    /// Applies a batch in order and adds to `touched` every node whose own props or child list
    /// changed (a removed node and its old parent included); returns the refused ops' issues.
    /// A renderer re-renders only those nodes (`AppSceneModel` slots).
    @discardableResult
    public mutating func apply(_ ops: [AppSceneOp], touched: inout Set<String>) -> [Issue] {
        var issues: [Issue] = []
        for op in ops {
            if let issue = apply(op, touched: &touched) { issues.append(issue) }
        }
        return issues
    }

    /// The node's parent; nil for the root, a detached node or an unknown id.
    public func parent(of id: String) -> String? { parent[id] }

    private mutating func apply(_ op: AppSceneOp, touched: inout Set<String>) -> Issue? {
        switch op {
        case let .create(id, type, props):
            guard let type = AppSceneNodeType(rawValue: type) else { return nil }
            guard nodes[id] == nil else { return .duplicateID(id) }
            guard nodes.count < Self.maxNodes else { return .nodeBudget }
            nodes[id] = AppSceneNode(type: type, props: props.filter { !$0.value.isNull })
            touched.insert(id)
        case let .update(id, props):
            guard var node = nodes[id] else { return nil }
            for (key, value) in props {
                if value.isNull { node.props.removeValue(forKey: key) } else { node.props[key] = value }
            }
            guard node != nodes[id] else { return nil }
            nodes[id] = node
            touched.insert(id)
        case let .children(id, children):
            guard var node = nodes[id] else { return nil }
            var seen = Set<String>()
            // Unknown or missing nodes and the node itself are skipped; an
            // id listed twice keeps its first place.
            let list = children.filter { nodes[$0] != nil && $0 != id && !isAncestor($0, of: id) && seen.insert($0).inserted }
            let depth = depth(of: id)
            if let deep = list.first(where: { depth + height(of: $0) > Self.maxDepth }) { return .depthBudget(deep) }
            guard list != node.children else { return nil }
            for old in node.children where parent[old] == id { parent.removeValue(forKey: old) }
            for child in list {
                if let previous = parent[child], previous != id {
                    detach(child, from: previous)
                    touched.insert(previous)
                }
                parent[child] = id
            }
            node.children = list
            nodes[id] = node
            touched.insert(id)
        case let .remove(id):
            guard nodes[id] != nil else { return nil }
            if let previous = parent[id] {
                detach(id, from: previous)
                touched.insert(previous)
            }
            removeSubtree(id, touched: &touched)
            if root == id { root = nil }
        case let .root(id):
            guard nodes[id] != nil else { return nil }
            if height(of: id) > Self.maxDepth { return .depthBudget(id) }
            root = id
        }
        return nil
    }

    /// Children of `id` with inline nodes (Group, ForEach) expanded in
    /// place, the way the parent stack lays them out.
    public func flattenedChildren(of id: String) -> [String] {
        var out: [String] = []
        for child in nodes[id]?.children ?? [] {
            if let node = nodes[child], node.type.isInline { out += flattenedChildren(of: child) } else { out.append(child) }
        }
        return out
    }

    /// 1 for the root level (a node without a parent).
    public func depth(of id: String) -> Int {
        var depth = 1
        var current = id
        while let up = parent[current], depth <= Self.maxNodes {
            depth += 1
            current = up
        }
        return depth
    }

    func height(of id: String) -> Int {
        1 + (nodes[id]?.children.map { height(of: $0) }.max() ?? 0)
    }

    private func isAncestor(_ candidate: String, of id: String) -> Bool {
        var current = id
        var steps = 0
        while let up = parent[current], steps <= Self.maxNodes {
            if up == candidate { return true }
            current = up
            steps += 1
        }
        return false
    }

    private mutating func detach(_ child: String, from id: String) {
        nodes[id]?.children.removeAll { $0 == child }
        parent.removeValue(forKey: child)
    }

    private mutating func removeSubtree(_ id: String, touched: inout Set<String>) {
        guard let node = nodes.removeValue(forKey: id) else { return }
        touched.insert(id)
        parent.removeValue(forKey: id)
        for child in node.children where parent[child] == id || parent[child] == nil { removeSubtree(child, touched: &touched) }
    }
}
