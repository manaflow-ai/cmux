import Foundation

/// A Git status entry that can be rendered as a file resource.
struct GitStatusSnapshotEntry: Equatable, Hashable, Sendable {
    let path: String
    let status: GitFileStatus
}
