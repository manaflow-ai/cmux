#if DEBUG
public import Foundation

/// An opaque token identifying one workspace created by the stress harness.
///
/// ``DebugStressWorkspaceDriver`` never sees a live `Workspace`; it carries the
/// workspace's stable id as a token and hands it back to
/// ``DebugStressWorkspaceHosting`` for every live operation. The host keeps the
/// token-to-`Workspace` mapping.
///
/// Isolation: a pure `Sendable`, `Hashable` value.
public struct DebugStressWorkspaceHandle: Sendable, Hashable {
    /// The created workspace's stable identifier.
    public var id: UUID

    /// Wraps a workspace id as a handle.
    public init(id: UUID) {
        self.id = id
    }
}
#endif
