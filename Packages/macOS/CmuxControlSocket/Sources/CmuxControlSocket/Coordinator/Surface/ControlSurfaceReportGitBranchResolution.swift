public import Foundation

/// The outcome of reporting or clearing Git branch metadata for a surface.
public enum ControlSurfaceReportGitBranchResolution: Sendable, Equatable {
    /// The workspace did not resolve.
    case workspaceNotFound
    /// The surface did not resolve.
    case surfaceNotFound
    /// The remote workspace has no surface yet, so the report was accepted for a later retry.
    case pending
    /// The metadata mutation completed for the resolved surface.
    case recorded(surfaceID: UUID)
}
