import Foundation

/// An optimistic workspace order that retains identity and intended membership only.
public struct MobileWorkspaceOptimisticOrder: Equatable, Sendable {
    /// Ordered workspace identities with their drag-intended memberships.
    public let entries: [MobileWorkspaceOptimisticOrderEntry]
    /// The group pin states the prediction was computed against.
    public let groupPins: [MobileWorkspaceGroupPreview.ID: Bool]

    /// Captures ordering intent from a workspace snapshot without retaining live row content.
    /// - Parameters:
    ///   - workspaces: The predicted workspace sequence.
    ///   - groups: The groups the prediction was computed against; their pin
    ///     states participate in staleness checks like workspace pins do.
    public init(workspaces: [MobileWorkspacePreview], groups: [MobileWorkspaceGroupPreview] = []) {
        entries = workspaces.map {
            MobileWorkspaceOptimisticOrderEntry(id: $0.id, groupID: $0.groupID, isPinned: $0.isPinned)
        }
        groupPins = Dictionary(groups.map { ($0.id, $0.isPinned) }, uniquingKeysWith: { first, _ in first })
    }

    /// Rebuilds the optimistic sequence from current authoritative row values.
    ///
    /// Existing rows keep the optimistic order and intended membership. Deleted
    /// rows disappear. New authoritative rows are inserted beside their nearest
    /// authoritative predecessor or successor, preserving their live content.
    /// - Parameter authoritative: The current authoritative workspace snapshot.
    /// - Returns: Live workspace values projected through this ordering intent.
    public func materializedWorkspaces(
        from authoritative: [MobileWorkspacePreview]
    ) -> [MobileWorkspacePreview] {
        let authoritativeByID = Dictionary(
            authoritative.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var result = entries.compactMap { entry -> MobileWorkspacePreview? in
            guard var workspace = authoritativeByID[entry.id] else { return nil }
            workspace.groupID = entry.groupID
            return workspace
        }
        var resultIDs = Set(result.map(\.id))

        for (index, workspace) in authoritative.enumerated() where !resultIDs.contains(workspace.id) {
            let precedingID = authoritative[..<index].reversed().lazy
                .map(\.id)
                .first(where: resultIDs.contains)
            if let precedingID,
               let resultIndex = result.firstIndex(where: { $0.id == precedingID }) {
                result.insert(workspace, at: result.index(after: resultIndex))
            } else {
                let followingID = authoritative[authoritative.index(after: index)...].lazy
                    .map(\.id)
                    .first(where: resultIDs.contains)
                if let followingID,
                   let resultIndex = result.firstIndex(where: { $0.id == followingID }) {
                    result.insert(workspace, at: resultIndex)
                } else {
                    result.append(workspace)
                }
            }
            resultIDs.insert(workspace.id)
        }
        return result
    }

    /// Returns whether the authoritative snapshot has reached this order,
    /// tolerating rows that arrived or disappeared while the move was pending.
    /// Pin-tier changes (workspace or group) invalidate the match outright:
    /// they change legal ordering, so the host may have clamped the predicted
    /// move to a no-op the prediction cannot represent.
    /// - Parameters:
    ///   - authoritative: The current authoritative workspace snapshot.
    ///   - groups: The current groups, for group-pin staleness.
    public func matches(
        authoritative: [MobileWorkspacePreview],
        groups: [MobileWorkspaceGroupPreview] = []
    ) -> Bool {
        for workspace in authoritative {
            if let entry = entries.first(where: { $0.id == workspace.id }),
               entry.isPinned != workspace.isPinned {
                return false
            }
        }
        for group in groups {
            if let capturedPin = groupPins[group.id], capturedPin != group.isPinned {
                return false
            }
        }
        return Self(workspaces: materializedWorkspaces(from: authoritative))
            == Self(workspaces: authoritative)
    }
}
