public import Foundation

/// The per-workspace value captured into a ``WorkspaceCreationSnapshot`` before
/// a new workspace boots: just the identity and pin state the insertion-index
/// math reads.
///
/// Lifted one-for-one from the legacy `TabManager.WorkspaceCreationTabSnapshot`
/// nested struct. It deliberately copies only `id`/`isPinned` out of the live
/// workspace so the snapshot stays a small `Sendable` value the placement math
/// can compute over without retaining any god-object state — the same reason
/// the legacy snapshot existed (the arm64 Nightly Cmd+N crash path dereferenced
/// pointer-backed terminal objects while preparing a new workspace, so the
/// pre-creation snapshot reads value-typed data only).
public struct WorkspaceCreationTabSnapshot: Sendable, Equatable {
    /// The workspace's stable identity.
    public let id: UUID
    /// Whether the workspace is pinned (pinned rows precede unpinned ones).
    public let isPinned: Bool

    /// Creates a snapshot from already-extracted value data.
    public init(id: UUID, isPinned: Bool) {
        self.id = id
        self.isPinned = isPinned
    }
}
