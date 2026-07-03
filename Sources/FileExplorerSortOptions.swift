import Foundation

struct FileExplorerSortOptions: Equatable, Sendable {
    let key: FileExplorerSortKey
    let order: FileExplorerSortOrder

    static let defaultValue = FileExplorerSortOptions(key: .name, order: .ascending)
}
