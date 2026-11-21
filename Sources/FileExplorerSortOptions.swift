import Foundation

/// A sort key and direction applied to every loaded level of the file explorer tree.
struct FileExplorerSortOptions: Equatable, Sendable {
    /// The attribute entries are ordered by.
    let key: FileExplorerSortKey
    /// The direction applied to `key`.
    let order: FileExplorerSortOrder

    /// Folders first, then names A to Z. This is the order the explorer used before sort options existed.
    static let defaultValue = FileExplorerSortOptions(key: .name, order: .ascending)
}
