import Foundation

/// Reports whether a path is backed by a local filesystem mount.
protocol GitFilesystemLocalityReading: Sendable {
    /// Returns false when the path is on a non-local or unknown mount.
    func isLocal(path: String) -> Bool
}
