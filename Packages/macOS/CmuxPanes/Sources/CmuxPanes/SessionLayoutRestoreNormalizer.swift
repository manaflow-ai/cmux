public import Foundation

/// Bounds restored pane trees using one shared node budget across containers.
///
/// Traversal is iterative and each result carries emptiness, so rebuilding a
/// split never recursively scans its children. One instance serves one restore.
public struct SessionLayoutRestoreNormalizer {
    private let maximumDepth: Int
    private var remainingNodes: Int
    /// Creates a traversal budget shared by every subsequent normalization.
    /// - Parameters:
    ///   - maximumNodes: Maximum input nodes visited across all containers.
    ///   - maximumDepth: Exclusive input depth limit, with root depth zero.
    public init(maximumNodes: Int, maximumDepth: Int) {
        remainingNodes = max(0, maximumNodes)
        self.maximumDepth = max(0, maximumDepth)
    }

    /// Filters invalid/duplicate panel references and collapses empty branches.
    /// - Parameters:
    ///   - layout: Saved topology to normalize.
    ///   - panelIDs: Admitted panel identities in fallback order.
    /// - Returns: The bounded tree and the number of admitted panels absent from the resulting tree.
    public mutating func normalize(
        _ layout: SessionWorkspaceLayoutSnapshot,
        panelIDs: [UUID]
    ) -> (layout: SessionWorkspaceLayoutSnapshot, droppedPanelCount: Int) {
        let allowed = Set(panelIDs)
        var usedPanelIDs = Set<UUID>()
        var nodes = remainingNodes
        let bounded = boundedLayout(
            layout, allowedPanelIDs: allowed, fallbackPanelIDs: panelIDs,
            depth: 0, remainingNodes: &nodes, usedPanelIDs: &usedPanelIDs
        )
        remainingNodes = nodes
        return (bounded.layout, allowed.subtracting(usedPanelIDs).count)
    }

    private func boundedLayout(
        _ layout: SessionWorkspaceLayoutSnapshot,
        allowedPanelIDs: Set<UUID>,
        fallbackPanelIDs: [UUID],
        depth: Int,
        remainingNodes: inout Int,
        usedPanelIDs: inout Set<UUID>
    ) -> SessionLayoutRestoreResult {
        func unusedFallbackPanelIDs() -> [UUID] {
            var result: [UUID] = []
            result.reserveCapacity(fallbackPanelIDs.count)
            for panelID in fallbackPanelIDs where allowedPanelIDs.contains(panelID) {
                guard usedPanelIDs.insert(panelID).inserted else { continue }
                result.append(panelID)
            }
            return result
        }
        func fallbackLayout() -> SessionLayoutRestoreResult {
            SessionLayoutRestoreResult(
                layout: .pane(SessionPaneLayoutSnapshot(
                    panelIds: [],
                    selectedPanelId: nil
                )),
                isEmpty: true
            )
        }

        // Walk the input graph with an explicit work stack. A depth check in
        // recursive code is insufficient: a hostile or corrupt snapshot can
        // consume the native stack before reaching that check.
        var work: [SessionLayoutRestoreWorkItem] = [.visit(layout, depth: depth)]
        var results: [SessionLayoutRestoreResult] = []
        results.reserveCapacity(min(remainingNodes, maximumDepth) + 1)

        while let item = work.popLast() {
            switch item {
            case let .visit(node, nodeDepth):
                guard remainingNodes > 0,
                      nodeDepth < maximumDepth else {
                    results.append(fallbackLayout())
                    continue
                }
                remainingNodes -= 1
                switch node {
                case .pane(let pane):
                    let panelIDs = pane.panelIds.filter {
                        allowedPanelIDs.contains($0) && usedPanelIDs.insert($0).inserted
                    }
                    let selected = pane.selectedPanelId.flatMap {
                        panelIDs.contains($0) ? $0 : nil
                    } ?? panelIDs.first
                    results.append(SessionLayoutRestoreResult(
                        layout: .pane(SessionPaneLayoutSnapshot(
                            panelIds: panelIDs,
                            selectedPanelId: selected,
                            isFullWidthTabMode: pane.isFullWidthTabMode
                        )),
                        isEmpty: panelIDs.isEmpty
                    ))
                case .split(let split):
                    work.append(.assemble(split))
                    work.append(.visit(split.second, depth: nodeDepth + 1))
                    work.append(.visit(split.first, depth: nodeDepth + 1))
                }
            case let .assemble(split):
                guard results.count >= 2 else {
                    results.append(fallbackLayout())
                    continue
                }
                let second = results.removeLast()
                let first = results.removeLast()
                switch (first.isEmpty, second.isEmpty) {
                case (true, true): results.append(fallbackLayout())
                case (true, false): results.append(second)
                case (false, true): results.append(first)
                case (false, false):
                    results.append(SessionLayoutRestoreResult(
                        layout: .split(SessionSplitLayoutSnapshot(
                            orientation: split.orientation,
                            dividerPosition: split.dividerPosition,
                            first: first.layout,
                            second: second.layout
                        )),
                        isEmpty: false
                    ))
                }
            }
        }
        let result = results.last ?? fallbackLayout()
        guard result.isEmpty else { return result }
        let fallback = unusedFallbackPanelIDs()
        return SessionLayoutRestoreResult(
            layout: .pane(SessionPaneLayoutSnapshot(
                panelIds: fallback,
                selectedPanelId: fallback.first
            )),
            isEmpty: fallback.isEmpty
        )
    }

}
