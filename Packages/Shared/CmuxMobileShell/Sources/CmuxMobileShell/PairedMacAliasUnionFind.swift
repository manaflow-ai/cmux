struct PairedMacAliasUnionFind {
    private var parentByID: [String: String] = [:]
    private var sizeByRoot: [String: Int] = [:]

    mutating func insert(_ id: String) {
        guard parentByID[id] == nil else { return }
        parentByID[id] = id
        sizeByRoot[id] = 1
    }

    mutating func root(of id: String) -> String {
        insert(id)
        let parent = parentByID[id] ?? id
        guard parent != id else { return id }
        let root = root(of: parent)
        parentByID[id] = root
        return root
    }

    mutating func union(_ lhs: String, _ rhs: String) {
        var lhsRoot = root(of: lhs)
        var rhsRoot = root(of: rhs)
        guard lhsRoot != rhsRoot else { return }
        if (sizeByRoot[lhsRoot] ?? 1) < (sizeByRoot[rhsRoot] ?? 1) {
            swap(&lhsRoot, &rhsRoot)
        }
        parentByID[rhsRoot] = lhsRoot
        sizeByRoot[lhsRoot] =
            (sizeByRoot[lhsRoot] ?? 1) + (sizeByRoot[rhsRoot] ?? 1)
        sizeByRoot[rhsRoot] = nil
    }
}
