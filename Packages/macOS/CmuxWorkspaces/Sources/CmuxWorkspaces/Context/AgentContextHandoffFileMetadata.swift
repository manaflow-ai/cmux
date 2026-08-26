import Foundation

/// Typed metadata the handoff verifier needs from its filesystem boundary.
nonisolated struct AgentContextHandoffFileMetadata: Equatable, Sendable {
    /// Whether the path currently identifies a regular file.
    let isRegularFile: Bool
    /// The file's modification date, when the filesystem provided one.
    let modificationDate: Date?
    /// The byte size reported by the filesystem.
    let size: Int
}
