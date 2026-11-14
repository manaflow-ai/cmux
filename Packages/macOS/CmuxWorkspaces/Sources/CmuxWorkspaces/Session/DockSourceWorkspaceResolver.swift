public import Foundation

/// Chooses the restored workspace a transferred Dock panel is rebuilt through.
///
/// A persisted workspace ID normally never repeats. An imported, edited or
/// corrupted session file can repeat one, and restore remints every copy after
/// the first. Among copies, the workspace whose Dock holds the panel wins,
/// because its snapshot carries the panel. Otherwise the first copy wins.
public struct DockSourceWorkspaceResolver: Sendable {
    private let originalWorkspaceIds: [UUID?]
    private let firstIndexByWorkspaceId: [UUID: Int]

    /// Creates a resolver over one restore batch's persisted workspace IDs, in
    /// restore order. Lookups are constant time after this single pass.
    public init(originalWorkspaceIds: [UUID?]) {
        self.originalWorkspaceIds = originalWorkspaceIds
        var firstIndexByWorkspaceId: [UUID: Int] = [:]
        firstIndexByWorkspaceId.reserveCapacity(originalWorkspaceIds.count)
        for (index, workspaceId) in originalWorkspaceIds.enumerated() {
            guard let workspaceId, firstIndexByWorkspaceId[workspaceId] == nil else { continue }
            firstIndexByWorkspaceId[workspaceId] = index
        }
        self.firstIndexByWorkspaceId = firstIndexByWorkspaceId
    }

    /// Returns the index of the workspace to rebuild through, or `nil` when no
    /// workspace in the batch has the source ID.
    public func workspaceIndex(
        sourceWorkspaceId: UUID,
        dockOwnerIndex: Int? = nil
    ) -> Int? {
        if let dockOwnerIndex,
           originalWorkspaceIds.indices.contains(dockOwnerIndex),
           originalWorkspaceIds[dockOwnerIndex] == sourceWorkspaceId {
            return dockOwnerIndex
        }
        return firstIndexByWorkspaceId[sourceWorkspaceId]
    }
}
