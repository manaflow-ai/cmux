import Foundation

/// One exact page from a direct-child directory listing.
struct MobileTaskDirectoryListPage: Equatable, Sendable {
    let currentPath: String
    let parentPath: String?
    let entries: [MobileTaskDirectoryListItem]
    let offset: Int
    let limit: Int
    let totalCount: Int
    let nextOffset: Int?
}
