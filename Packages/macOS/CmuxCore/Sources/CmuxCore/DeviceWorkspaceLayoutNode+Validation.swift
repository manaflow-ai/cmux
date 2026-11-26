extension DeviceWorkspaceLayoutNode {
    /// Validates a bounded tree and returns its terminal IDs in pane/tab order.
    /// - Parameters:
    ///   - maximumSurfaceCount: Maximum number of terminals accepted in one workspace.
    ///   - maximumDepth: Maximum number of nested split/pane nodes.
    /// - Returns: Unique terminal IDs in their visible ordering.
    /// - Throws: ``DeviceWorkspaceLayoutValidationError`` for an invalid tree.
    public func validatedSurfaceIDs(maximumSurfaceCount: Int = 512, maximumDepth: Int = 64) throws -> [String] {
        var ids: [String] = []
        var seen = Set<String>()
        try collectSurfaceIDs(into: &ids, seen: &seen, remainingDepth: maximumDepth, maximumCount: maximumSurfaceCount)
        return ids
    }

    /// Replaces viewer panel IDs with their owning Mac's terminal IDs.
    ///
    /// The mapping must cover every panel. Mixed local/remote workspaces cannot
    /// silently lose their local panels when a remote layout is submitted.
    /// - Parameter mapping: Local panel ID to remote terminal ID.
    /// - Returns: The same pane tree, order, divider proportions, and selection.
    /// - Throws: ``DeviceWorkspaceLayoutValidationError`` when a panel is unmapped.
    public func remappingSurfaceIDs(_ mapping: [String: String]) throws -> Self {
        switch self {
        case .pane(let id, let surfaces, let selected):
            let mapped = try surfaces.map { surface -> String in
                guard let result = mapping[surface] else { throw DeviceWorkspaceLayoutValidationError.unmappedSurface }
                return result
            }
            let selected = try selected.map { surface -> String in
                guard let result = mapping[surface] else { throw DeviceWorkspaceLayoutValidationError.unmappedSurface }
                return result
            }
            return .pane(id: id, surfaceIDs: mapped, selectedSurfaceID: selected)
        case .split(let direction, let ratio, let first, let second):
            return .split(direction: direction, ratio: ratio,
                first: try first.remappingSurfaceIDs(mapping), second: try second.remappingSurfaceIDs(mapping))
        }
    }

    /// Compares structural edits independently of per-Mac pane IDs and focus.
    /// - Parameter other: A layout using the same owning-terminal ID namespace.
    /// - Returns: Whether tab ordering, split directions, and proportions agree.
    public func hasSameArrangement(as other: Self) -> Bool {
        switch (self, other) {
        case (.pane(_, let a, _), .pane(_, let b, _)):
            return a == b
        case (.split(let aDirection, let aRatio, let aFirst, let aSecond),
              .split(let bDirection, let bRatio, let bFirst, let bSecond)):
            return aDirection == bDirection && abs(aRatio - bRatio) < 0.0001
                && aFirst.hasSameArrangement(as: bFirst) && aSecond.hasSameArrangement(as: bSecond)
        default:
            return false
        }
    }

    private func collectSurfaceIDs(into ids: inout [String], seen: inout Set<String>, remainingDepth: Int, maximumCount: Int) throws {
        guard remainingDepth > 0 else { throw DeviceWorkspaceLayoutValidationError.limitExceeded }
        switch self {
        case .pane(let id, let surfaces, let selected):
            guard !id.isEmpty, !surfaces.isEmpty, selected.map({ surfaces.contains($0) }) ?? true else {
                throw DeviceWorkspaceLayoutValidationError.invalidPane
            }
            for surface in surfaces {
                guard !surface.isEmpty else { throw DeviceWorkspaceLayoutValidationError.invalidPane }
                guard ids.count < maximumCount else { throw DeviceWorkspaceLayoutValidationError.limitExceeded }
                guard seen.insert(surface).inserted else { throw DeviceWorkspaceLayoutValidationError.duplicateSurface }
                ids.append(surface)
            }
        case .split(_, let ratio, let first, let second):
            guard ratio.isFinite, ratio > 0, ratio < 1 else { throw DeviceWorkspaceLayoutValidationError.invalidSplitRatio }
            try first.collectSurfaceIDs(into: &ids, seen: &seen, remainingDepth: remainingDepth - 1, maximumCount: maximumCount)
            try second.collectSurfaceIDs(into: &ids, seen: &seen, remainingDepth: remainingDepth - 1, maximumCount: maximumCount)
        }
    }
}
