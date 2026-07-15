import CmuxMobileRPC

struct DiffTreeAccumulator: Sendable {
    let name: String
    let path: String
    var status: MobileDiffFileStatus?
    var children: [String: DiffTreeAccumulator]

    init(name: String = "", path: String = "") {
        self.name = name
        self.path = path
        status = nil
        children = [:]
    }

    mutating func insert(components: ArraySlice<Substring>, status: MobileDiffFileStatus) {
        guard let component = components.first else {
            self.status = status
            return
        }
        let name = String(component)
        let childPath = path.isEmpty ? name : "\(path)/\(name)"
        var child = children[name] ?? DiffTreeAccumulator(name: name, path: childPath)
        child.insert(components: components.dropFirst(), status: status)
        children[name] = child
    }

    func node() -> DiffTreeNode {
        if let status {
            return DiffTreeNode(name: name, path: path, kind: .file(status), children: [])
        }
        var displayName = name
        var displayPath = path
        var displayChildren = children.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        while displayChildren.count == 1, displayChildren[0].status == nil {
            let onlyChild = displayChildren[0]
            displayName = displayName.isEmpty ? onlyChild.name : "\(displayName)/\(onlyChild.name)"
            displayPath = onlyChild.path
            displayChildren = onlyChild.children.values.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
        return DiffTreeNode(
            name: displayName,
            path: displayPath,
            kind: .directory,
            children: displayChildren.map { $0.node() }
        )
    }
}
