import Foundation

/// One exact page from a direct-child directory listing.
public struct MobileTaskDirectoryListPage: Equatable, Sendable {
    public let currentPath: String
    public let parentPath: String?
    public let entries: [MobileTaskDirectoryListItem]
    public let offset: Int
    public let limit: Int
    public let totalCount: Int
    public let nextOffset: Int?
}
