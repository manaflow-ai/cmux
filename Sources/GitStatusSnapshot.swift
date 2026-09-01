import Foundation

/// Immutable result of one Git status read.
///
/// ``statusesByPath`` retains synthesized parent-directory decorations for the
/// Files tree, while ``displayableEntries`` contains only real status resources
/// for list-style consumers such as Source Control. Building that distinction
/// with the status result keeps filesystem probes out of SwiftUI render paths.
struct GitStatusSnapshot: Equatable, Sendable {
    static let empty = Self(statusesByPath: [:], displayableEntries: [], state: .unavailable)

    let statusesByPath: [String: GitFileStatus]
    let displayableEntries: [GitStatusSnapshotEntry]
    let state: GitStatusSnapshotState

    init(
        statusesByPath: [String: GitFileStatus],
        displayableEntries: [GitStatusSnapshotEntry],
        state: GitStatusSnapshotState = .available
    ) {
        self.statusesByPath = statusesByPath
        self.displayableEntries = displayableEntries
        self.state = state
    }
}
