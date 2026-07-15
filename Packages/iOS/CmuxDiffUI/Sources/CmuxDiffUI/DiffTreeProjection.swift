struct DiffTreeProjection: Sendable {
    func rows(
        nodes: [DiffTreeNode],
        files: [DiffFilePresentationState],
        collapsedPaths: Set<String>
    ) -> [DiffTreeRowSnapshot] {
        let states = Dictionary(uniqueKeysWithValues: files.map { ($0.file.summary.path, $0) })
        var result: [DiffTreeRowSnapshot] = []
        append(
            nodes: nodes,
            depth: 0,
            states: states,
            collapsedPaths: collapsedPaths,
            result: &result
        )
        return result
    }

    private func append(
        nodes: [DiffTreeNode],
        depth: Int,
        states: [String: DiffFilePresentationState],
        collapsedPaths: Set<String>,
        result: inout [DiffTreeRowSnapshot]
    ) {
        for node in nodes {
            switch node.kind {
            case .directory:
                let descendants = descendantStates(node: node, states: states)
                let isExpanded = !collapsedPaths.contains(node.path)
                result.append(DiffTreeRowSnapshot(
                    name: node.name,
                    path: node.path,
                    depth: depth,
                    kind: .directory(isExpanded: isExpanded),
                    additions: descendants.reduce(0) { $0 + $1.file.summary.additions },
                    deletions: descendants.reduce(0) { $0 + $1.file.summary.deletions },
                    fileCount: descendants.count,
                    isViewed: !descendants.isEmpty && descendants.allSatisfy(\.isViewed)
                ))
                if isExpanded {
                    append(
                        nodes: node.children,
                        depth: depth + 1,
                        states: states,
                        collapsedPaths: collapsedPaths,
                        result: &result
                    )
                }
            case let .file(status):
                guard let state = states[node.path] else { continue }
                result.append(DiffTreeRowSnapshot(
                    name: node.name,
                    path: node.path,
                    depth: depth,
                    kind: .file(status),
                    additions: state.file.summary.additions,
                    deletions: state.file.summary.deletions,
                    fileCount: 1,
                    isViewed: state.isViewed
                ))
            }
        }
    }

    private func descendantStates(
        node: DiffTreeNode,
        states: [String: DiffFilePresentationState]
    ) -> [DiffFilePresentationState] {
        node.children.flatMap { child in
            switch child.kind {
            case .directory:
                descendantStates(node: child, states: states)
            case .file:
                states[child.path].map { [$0] } ?? []
            }
        }
    }
}
