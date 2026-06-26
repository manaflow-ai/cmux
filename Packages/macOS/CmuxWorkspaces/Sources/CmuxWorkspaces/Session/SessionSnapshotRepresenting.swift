public import Foundation

/// Seam satisfied by the app's session snapshot root (`AppSessionSnapshot`).
///
/// The repository is generic over this protocol so the snapshot DTO graph
/// (and therefore the on-disk wire format) stays owned by the app target:
/// the repository encodes and decodes whatever conforming value the app
/// hands it, byte-for-byte through the same `Codable` synthesis.
public protocol SessionSnapshotRepresenting: Codable, Sendable {
    /// The schema version persisted inside the snapshot payload.
    var version: Int { get }
    /// A copy of the snapshot with every non-restorable window removed, or
    /// `nil` when no restorable window remains. A non-restorable window is an
    /// "empty shell" that carries no tabs/surfaces: such windows are persisted
    /// across an unclean shutdown and, when replayed on launch, create
    /// content-less windows that can wedge the macOS WindowServer and freeze
    /// the desktop (issue #6646). The persistence layer discards them on load
    /// (an all-phantom snapshot is treated as unusable, like an empty window
    /// list) so a corrupt session never replays into a hang.
    var discardingNonRestorableWindows: Self? { get }
}
