public import Foundation

/// Outcome of `workstream.list`.
public enum ControlWorkstreamListResolution: Sendable, Equatable {
    /// No TabManager resolved.
    case tabManagerUnavailable
    /// The workstreams were snapshotted. Carries the owning window id (may be
    /// absent), the workstreams in master-list order, and the currently
    /// drilled-into workstream id (nil at the top level).
    case resolved(windowID: UUID?, workstreams: [ControlWorkstreamSnapshot], drilledInWorkstreamID: UUID?)
}

/// Outcome of `workstream.create`.
public enum ControlWorkstreamCreateResolution: Sendable, Equatable {
    /// No TabManager resolved.
    case tabManagerUnavailable
    /// One or more requested member workspaces don't exist in the target window.
    case workspaceNotFound([String])
    /// The workstream was created.
    case created(ControlWorkstreamSnapshot)
}
