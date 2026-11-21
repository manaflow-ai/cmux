/// The words a scene shows, for reading a view back without a picture (`apps.views`).
extension AppScene {
    /// Each node's `text`, `title`, `subtitle` and `detail`, depth first from the root, in the order
    /// the view lays them out; empty while nothing has rendered.
    public func texts() -> [String] {
        guard let root else { return [] }
        var out: [String] = []
        var stack = [root]
        var visited = 0
        while let id = stack.popLast(), visited < Self.maxNodes {
            visited += 1
            guard let node = nodes[id] else { continue }
            for key in ["title", "text", "subtitle", "detail"] {
                if let value = node.string(key), !value.isEmpty { out.append(value) }
            }
            stack.append(contentsOf: node.children.reversed())
        }
        return out
    }
}
