/// A user-actionable failure returned by task-composer directory browsing.
public enum MobileTaskDirectoryListFailure: Error, Equatable, Sendable {
    /// The requested path or pagination values are not valid for the browse RPC.
    case invalidPath
    /// The selected Mac could not be reached.
    case unavailable
    /// The Mac did not finish the directory listing before its deadline.
    case timedOut
    /// The phone or Mac must be signed in again before browsing can continue.
    case authorizationRequired
    /// The selected Mac predates hierarchical directory browsing.
    case unsupported
    /// The requested path no longer exists on the Mac.
    case notFound
    /// The requested path exists but is not a directory.
    case notDirectory
    /// macOS denied permission to enumerate the requested directory.
    case permissionDenied
    /// The requested directory exists but cannot be read.
    case unreadable
    /// The Mac rejected the request or returned a malformed page.
    case rejected
    /// The caller superseded or cancelled this listing.
    case cancelled
}
