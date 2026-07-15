/// Serializes headless background terminal startup.
///
/// Each pending workspace is attempted once per pass, with one active wait at a time. Terminal
/// runtime lifecycle owns the headless AppKit host.
public struct BackgroundWorkspaceHeadlessPrimeSchedule<WorkspaceID: Hashable & Sendable>: Sendable {
    public enum Resolution: Sendable {
        case completed
        case timeout
        case cancelled
        case workspaceRemoved
    }

    public private(set) var activeWorkspaceID: WorkspaceID?
    private var attemptedWorkspaceIDs: Set<WorkspaceID> = []

    public init() {}

    public mutating func nextWorkspaceID(
        orderedPendingWorkspaceIDs: [WorkspaceID]
    ) -> WorkspaceID? {
        let pendingWorkspaceIDs = Set(orderedPendingWorkspaceIDs)
        attemptedWorkspaceIDs.formIntersection(pendingWorkspaceIDs)

        if let activeWorkspaceID,
           pendingWorkspaceIDs.contains(activeWorkspaceID) {
            return activeWorkspaceID
        }

        if let nextWorkspaceID = orderedPendingWorkspaceIDs.first(where: {
            !attemptedWorkspaceIDs.contains($0)
        }) {
            attemptedWorkspaceIDs.insert(nextWorkspaceID)
            activeWorkspaceID = nextWorkspaceID
            return nextWorkspaceID
        }

        attemptedWorkspaceIDs.removeAll(keepingCapacity: true)
        activeWorkspaceID = orderedPendingWorkspaceIDs.first
        if let activeWorkspaceID {
            attemptedWorkspaceIDs.insert(activeWorkspaceID)
        }
        return activeWorkspaceID
    }

    public mutating func resolve(
        workspaceID: WorkspaceID,
        resolution: Resolution
    ) {
        guard activeWorkspaceID == workspaceID else { return }

        switch resolution {
        case .completed, .timeout, .cancelled, .workspaceRemoved:
            activeWorkspaceID = nil
        }
    }
}
