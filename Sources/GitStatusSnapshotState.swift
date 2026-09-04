import Foundation

/// Whether a Git status read produced an authoritative repository snapshot.
enum GitStatusSnapshotState: Equatable, Sendable {
    case unavailable
    case available
}
