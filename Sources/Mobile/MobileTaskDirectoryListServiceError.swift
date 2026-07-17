import Foundation

/// Filesystem failures that the directory-list RPC exposes without collapsing
/// user-actionable conditions into a generic internal error.
enum MobileTaskDirectoryListServiceError: Error, Equatable {
    case invalidRequest
    case invalidPath
    case notFound
    case notDirectory
    case permissionDenied
    case unreadable
}
