public import Foundation

/// Tracks which of an incoming workspace's visible terminals have rendered a
/// frame since a workspace switch began. The handoff keeps the retiring
/// workspace's content on screen until this plan completes (or a bounded
/// timeout fires), so a switch never paints a frame with neither workspace's
/// terminal content (manaflow-ai/cmux#1291).
public struct WorkspaceHandoffFramePlan: Equatable {
    public let workspaceId: UUID
    public private(set) var pendingSurfaceIds: Set<UUID>

    public init(workspaceId: UUID, expectedSurfaceIds: Set<UUID>) {
        self.workspaceId = workspaceId
        self.pendingSurfaceIds = expectedSurfaceIds
    }

    /// A plan with no expected surfaces is complete from the start (a
    /// browser-only or empty workspace has no terminal frame to wait for).
    public var isComplete: Bool { pendingSurfaceIds.isEmpty }

    /// Records one rendered frame. Returns `true` exactly when this frame
    /// completed the plan, so the caller fires its ready action once.
    @discardableResult
    public mutating func recordFrame(workspaceId: UUID, surfaceId: UUID) -> Bool {
        guard workspaceId == self.workspaceId else { return false }
        guard !isComplete else { return false }
        pendingSurfaceIds.remove(surfaceId)
        return isComplete
    }
}
