import Foundation

/// Immutable result of one Git status read.
///
/// ``statusesByPath`` retains synthesized parent-directory decorations for the
/// Files tree, while ``displayableEntries`` contains only real status resources
/// for list-style consumers such as Source Control. Building that distinction
/// with the status result keeps filesystem probes out of SwiftUI render paths.
struct GitStatusSnapshot: Equatable, Sendable {
    static let empty = Self(statusesByPath: [:], displayableEntries: [])

    let statusesByPath: [String: GitFileStatus]
    let displayableEntries: [GitStatusSnapshotEntry]
}
