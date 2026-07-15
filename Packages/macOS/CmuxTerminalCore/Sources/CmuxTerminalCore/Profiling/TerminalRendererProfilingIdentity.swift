public import Foundation

/// Stable, privacy-safe identifiers used to correlate one terminal renderer across lifecycle changes.
public struct TerminalRendererProfilingIdentity: Equatable, Sendable {
    /// The workspace that owns the terminal surface.
    public let workspaceId: UUID

    /// The stable terminal-surface identifier.
    public let surfaceId: UUID

    /// Creates a renderer identity from cmux-owned opaque identifiers.
    public init(workspaceId: UUID, surfaceId: UUID) {
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
    }
}
