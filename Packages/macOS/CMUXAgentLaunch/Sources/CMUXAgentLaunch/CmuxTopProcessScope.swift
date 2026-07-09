import Foundation

/// The cmux ownership a sampled process resolves to: the workspace and/or surface
/// it belongs to, plus the reason that attribution was derived (inherited
/// environment vs. hook arguments). Carried on each `CmuxTopProcessInfo`.
public struct CmuxTopProcessScope: Sendable, Equatable {
    /// The owning workspace, if known.
    public let workspaceID: UUID?
    /// The owning surface, if known.
    public let surfaceID: UUID?
    /// How the scope was determined (e.g. `"cmux-environment"`, `"cmux-hook-arguments"`).
    public let attributionReason: String

    /// Creates a process scope.
    public init(workspaceID: UUID?, surfaceID: UUID?, attributionReason: String) {
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.attributionReason = attributionReason
    }
}
