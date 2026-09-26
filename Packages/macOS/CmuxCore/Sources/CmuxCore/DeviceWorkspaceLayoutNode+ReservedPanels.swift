extension DeviceWorkspaceLayoutNode {
    /// Drops panels the owning Mac does not know. An emptied pane yields its
    /// space to its sibling, and a pane whose selected panel left keeps no
    /// selection.
    /// - Parameter removed: Panel IDs to drop.
    /// - Returns: The remaining tree, or `nil` when every panel was removed.
    public func removingSurfaceIDs(_ removed: Set<String>) -> Self? {
        guard !removed.isEmpty else { return self }
        switch self {
        case .pane(let id, let surfaces, let selected):
            let kept = surfaces.filter { !removed.contains($0) }
            guard !kept.isEmpty else { return nil }
            return .pane(id: id, surfaceIDs: kept, selectedSurfaceID: selected.flatMap { kept.contains($0) ? $0 : nil })
        case .split(let direction, let ratio, let first, let second):
            switch (first.removingSurfaceIDs(removed), second.removingSurfaceIDs(removed)) {
            case (let first?, let second?): return .split(direction: direction, ratio: ratio, first: first, second: second)
            case (let only?, nil), (nil, let only?): return only
            case (nil, nil): return nil
            }
        }
    }

    /// Restores `kept` panels, which the owning Mac does not know, where
    /// `local` shows them.
    ///
    /// A kept tab goes beside its nearest neighbor from the same local pane:
    /// after the previous one, else before the next one. A local split whose
    /// whole side is kept restores that side, with its direction and ratio,
    /// around the smallest subtree holding the other side's terminals. A panel
    /// with no placed neighbor goes at the end of the last pane, in local
    /// order, then sorted for panels `local` does not contain.
    ///
    /// Each surface, pane, and local node is indexed once. The cost is linear
    /// in the panels of both trees, plus the depth of this tree for each
    /// restored split.
    /// - Parameters:
    ///   - kept: Panel IDs to restore. They should not already appear in this tree.
    ///   - local: The viewer's layout, which places the kept panels.
    /// - Returns: This tree with every kept panel placed exactly once.
    public func grafting(_ kept: Set<String>, from local: Self) -> Self {
        guard !kept.isEmpty else { return self }
        var graft = DeviceWorkspaceLayoutGraft(target: self, kept: kept, local: local)
        graft.graft(graft.localRoot)
        return graft.result()
    }
}

/// The mutable indexes behind ``DeviceWorkspaceLayoutNode/grafting(_:from:)``.
private struct DeviceWorkspaceLayoutGraft {
    private enum TargetNode {
        case pane(id: String, surfaces: [String], selected: String?)
        case split(direction: DeviceWorkspaceLayoutNode.Direction, ratio: Double, first: Int, second: Int)
        case restored(DeviceWorkspaceLayoutNode)
    }

    private struct LocalNode {
        let node: DeviceWorkspaceLayoutNode
        var children: (first: Int, second: Int)?
        var hasSurfaces: Bool
        /// Whether every panel in the subtree is kept, vacuously for none.
        var allKept: Bool
        /// Target positions of the subtree's panels the target already shows.
        var targetPositions: ClosedRange<Int>?
    }

    private let kept: Set<String>
    private var targetNodes: [TargetNode] = []
    private var targetParents: [Int?] = []
    private var targetRoot = 0
    /// The target pane holding the panel at each position, in tree order.
    private var targetPaneAtPosition: [Int] = []
    private var targetPositionBySurface: [String: Int] = [:]
    private var localNodes: [LocalNode] = []
    private(set) var localRoot = 0
    private var localOrder: [String] = []
    /// Panels the result holds so far: the target's, then restored ones.
    private var present: Set<String> = []
    /// Kept tabs to place before or after an anchor panel, in insertion order.
    private var tabsBefore: [String: [String]] = [:]
    private var tabsAfter: [String: [String]] = [:]
    private var ancestorMarks: [Int] = []
    private var markGeneration = 0

    init(target: DeviceWorkspaceLayoutNode, kept: Set<String>, local: DeviceWorkspaceLayoutNode) {
        self.kept = kept
        targetRoot = indexTarget(target, parent: nil)
        present = Set(targetPositionBySurface.keys)
        localRoot = indexLocal(local)
    }

    /// Restores kept panels from one local subtree, in local pre-order.
    mutating func graft(_ index: Int) {
        let entry = localNodes[index]
        switch entry.node {
        case .pane(_, let surfaces, _):
            graftTabs(surfaces)
        case .split(let direction, let ratio, _, _):
            guard let children = entry.children else { return }
            let firstIsKept = isKept(children.first)
            guard firstIsKept != isKept(children.second) else {
                graft(children.first)
                graft(children.second)
                return
            }
            let (branch, sibling) = firstIsKept ? (children.first, children.second) : (children.second, children.first)
            if let positions = localNodes[sibling].targetPositions {
                let anchor = lowestCommonAncestor(
                    targetPaneAtPosition[positions.lowerBound],
                    targetPaneAtPosition[positions.upperBound]
                )
                wrap(anchor, with: localNodes[branch].node, direction: direction, ratio: ratio, branchFirst: firstIsKept)
            }
            graft(sibling)
        }
    }

    /// Builds the grafted tree and places panels no neighbor anchored.
    mutating func result() -> DeviceWorkspaceLayoutNode {
        var seen = Set<String>()
        var stranded = localOrder.filter { kept.contains($0) && !present.contains($0) && seen.insert($0).inserted }
        stranded += kept.subtracting(present).subtracting(seen).sorted()
        let tree = build(targetRoot)
        guard !stranded.isEmpty else { return tree }
        return Self.appending(stranded, toLastPaneOf: tree) ?? tree
    }

    /// Whether a local subtree has panels and every one of them is kept.
    private func isKept(_ index: Int) -> Bool {
        localNodes[index].hasSurfaces && localNodes[index].allKept
    }

    // MARK: Indexing

    private mutating func indexTarget(_ node: DeviceWorkspaceLayoutNode, parent: Int?) -> Int {
        let index = targetNodes.count
        targetNodes.append(.restored(node))
        targetParents.append(parent)
        switch node {
        case .pane(let id, let surfaces, let selected):
            targetNodes[index] = .pane(id: id, surfaces: surfaces, selected: selected)
            for surface in surfaces where targetPositionBySurface[surface] == nil {
                targetPositionBySurface[surface] = targetPaneAtPosition.count
                targetPaneAtPosition.append(index)
            }
        case .split(let direction, let ratio, let first, let second):
            let firstIndex = indexTarget(first, parent: index)
            let secondIndex = indexTarget(second, parent: index)
            targetNodes[index] = .split(direction: direction, ratio: ratio, first: firstIndex, second: secondIndex)
        }
        return index
    }

    private mutating func indexLocal(_ node: DeviceWorkspaceLayoutNode) -> Int {
        let index = localNodes.count
        localNodes.append(LocalNode(node: node, children: nil, hasSurfaces: false, allKept: true, targetPositions: nil))
        switch node {
        case .pane(_, let surfaces, _):
            localOrder += surfaces
            localNodes[index].hasSurfaces = !surfaces.isEmpty
            localNodes[index].allKept = surfaces.allSatisfy(kept.contains)
            for surface in surfaces {
                guard let position = targetPositionBySurface[surface] else { continue }
                localNodes[index].targetPositions = Self.union(localNodes[index].targetPositions, position...position)
            }
        case .split(_, _, let first, let second):
            let firstIndex = indexLocal(first)
            let secondIndex = indexLocal(second)
            let firstNode = localNodes[firstIndex]
            let secondNode = localNodes[secondIndex]
            localNodes[index].children = (firstIndex, secondIndex)
            localNodes[index].hasSurfaces = firstNode.hasSurfaces || secondNode.hasSurfaces
            localNodes[index].allKept = firstNode.allKept && secondNode.allKept
            localNodes[index].targetPositions = Self.union(firstNode.targetPositions, secondNode.targetPositions)
        }
        return index
    }

    private static func union(_ lhs: ClosedRange<Int>?, _ rhs: ClosedRange<Int>?) -> ClosedRange<Int>? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return min(lhs.lowerBound, rhs.lowerBound)...max(lhs.upperBound, rhs.upperBound)
    }

    // MARK: Grafting

    /// Anchors each kept tab to its previous placed neighbor in the local
    /// pane, or, for tabs before any placed neighbor, to the next one.
    private mutating func graftTabs(_ surfaces: [String]) {
        var previous: String?
        for (index, surface) in surfaces.enumerated() {
            if present.contains(surface) {
                previous = surface
                continue
            }
            guard kept.contains(surface) else { continue }
            if let anchor = previous {
                tabsAfter[anchor, default: []].append(surface)
            } else if let anchor = surfaces[(index + 1)...].first(where: present.contains) {
                tabsBefore[anchor, default: []].append(surface)
            } else {
                // No placed neighbor before or after, so none of the rest has one.
                return
            }
            present.insert(surface)
            previous = surface
        }
    }

    /// Splits `index`'s subtree, placing `branch` on the side `local` had it.
    private mutating func wrap(_ index: Int, with branch: DeviceWorkspaceLayoutNode,
                               direction: DeviceWorkspaceLayoutNode.Direction, ratio: Double, branchFirst: Bool) {
        let parent = targetParents[index]
        let branchIndex = targetNodes.count
        targetNodes.append(.restored(branch))
        let splitIndex = targetNodes.count
        targetNodes.append(.split(direction: direction, ratio: ratio,
            first: branchFirst ? branchIndex : index, second: branchFirst ? index : branchIndex))
        targetParents.append(splitIndex)
        targetParents.append(parent)
        targetParents[index] = splitIndex
        if let parent {
            if case .split(let ownDirection, let ownRatio, let first, let second) = targetNodes[parent] {
                targetNodes[parent] = .split(direction: ownDirection, ratio: ownRatio,
                    first: first == index ? splitIndex : first, second: second == index ? splitIndex : second)
            }
        } else {
            targetRoot = splitIndex
        }
        Self.forEachSurface(in: branch) { present.insert($0) }
    }

    private mutating func lowestCommonAncestor(_ lhs: Int, _ rhs: Int) -> Int {
        markGeneration += 1
        if ancestorMarks.count < targetNodes.count {
            ancestorMarks += Array(repeating: 0, count: targetNodes.count - ancestorMarks.count)
        }
        var node: Int? = lhs
        while let current = node {
            ancestorMarks[current] = markGeneration
            node = targetParents[current]
        }
        node = rhs
        while let current = node {
            if ancestorMarks[current] == markGeneration { return current }
            node = targetParents[current]
        }
        return targetRoot
    }

    // MARK: Building

    private mutating func build(_ index: Int) -> DeviceWorkspaceLayoutNode {
        switch targetNodes[index] {
        case .pane(let id, let surfaces, let selected):
            return .pane(id: id, surfaceIDs: placingTabs(around: surfaces), selectedSurfaceID: selected)
        case .split(let direction, let ratio, let first, let second):
            return .split(direction: direction, ratio: ratio, first: build(first), second: build(second))
        case .restored(let node):
            return placingTabs(in: node)
        }
    }

    private mutating func placingTabs(in node: DeviceWorkspaceLayoutNode) -> DeviceWorkspaceLayoutNode {
        switch node {
        case .pane(let id, let surfaces, let selected):
            return .pane(id: id, surfaceIDs: placingTabs(around: surfaces), selectedSurfaceID: selected)
        case .split(let direction, let ratio, let first, let second):
            return .split(direction: direction, ratio: ratio, first: placingTabs(in: first), second: placingTabs(in: second))
        }
    }

    /// Expands each panel into the tabs anchored before it, itself, then the
    /// tabs anchored after it. A later tab anchored after the same panel sits
    /// closer to it, as a sequence of single inserts would leave it.
    private mutating func placingTabs(around surfaces: [String]) -> [String] {
        guard !tabsBefore.isEmpty || !tabsAfter.isEmpty else { return surfaces }
        enum Step { case expand(String), emit(String) }
        var result: [String] = []
        result.reserveCapacity(surfaces.count)
        var steps = surfaces.reversed().map(Step.expand)
        while let step = steps.popLast() {
            switch step {
            case .emit(let surface):
                result.append(surface)
            case .expand(let surface):
                // Each anchor's tabs are placed once.
                steps += (tabsAfter.removeValue(forKey: surface) ?? []).map(Step.expand)
                steps.append(.emit(surface))
                steps += (tabsBefore.removeValue(forKey: surface) ?? []).reversed().map(Step.expand)
            }
        }
        return result
    }

    private static func appending(_ surfaces: [String], toLastPaneOf node: DeviceWorkspaceLayoutNode) -> DeviceWorkspaceLayoutNode? {
        switch node {
        case .pane(let id, let existing, let selected):
            guard !existing.isEmpty else { return nil }
            return .pane(id: id, surfaceIDs: existing + surfaces, selectedSurfaceID: selected)
        case .split(let direction, let ratio, let first, let second):
            if let second = appending(surfaces, toLastPaneOf: second) {
                return .split(direction: direction, ratio: ratio, first: first, second: second)
            }
            guard let first = appending(surfaces, toLastPaneOf: first) else { return nil }
            return .split(direction: direction, ratio: ratio, first: first, second: second)
        }
    }

    private static func forEachSurface(in node: DeviceWorkspaceLayoutNode, _ body: (String) -> Void) {
        switch node {
        case .pane(_, let surfaces, _):
            surfaces.forEach(body)
        case .split(_, _, let first, let second):
            forEachSurface(in: first, body)
            forEachSurface(in: second, body)
        }
    }
}
