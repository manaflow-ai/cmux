/// Typed artifact failures surfaced by chat event sources.
public enum ChatArtifactError: Error, Sendable, Equatable {
    /// The connected Mac or fixture source does not support artifact RPCs.
    case unsupported
    /// The request parameters were malformed.
    case invalidParams
    /// The chat session no longer exists on the Mac.
    case sessionNotFound
    /// The chat session exists, but its transcript or artifact index cannot be read.
    case sessionUnavailable
    /// The terminal authorizing the requested path no longer exists on the Mac.
    case terminalNotFound
    /// The workspace authorizing the requested path no longer exists on the Mac.
    case workspaceNotFound
    /// The workspace directory is no longer a Git repository.
    case notRepository
    /// The requested path was not referenced by the session.
    case forbidden
    /// The path was in scope but no longer exists on the Mac.
    case fileNotFound
    /// The Mac found the path but does not have permission to read it.
    case permissionDenied
    /// A directory listing was requested for a path that is not a directory.
    case notDirectory
    /// File bytes were requested for a path that is not a regular file.
    case notRegularFile
    /// The Mac found the file but could not read its metadata or bytes.
    case fileReadFailed
    /// The file changed after the transfer began.
    case fileChanged
    /// The operation does not apply to this media type.
    case unsupportedMedia
    /// The media type is supported, but its data is damaged or invalid.
    case corruptMedia
    /// Valid media data could not be converted into a preview.
    case previewFailed
    /// The Mac-side artifact service is not wired.
    case unavailable
    /// The Mac or transport returned malformed or inconsistent transfer data.
    case invalidResponse
    /// A transfer ended after starting but before all bytes arrived.
    case transferInterrupted
    /// The file request did not complete before its deadline.
    case requestTimedOut
    /// An equivalent connection attempt is already in progress.
    case connectionRecovering
    /// Stuck connection cleanup prevents another attempt until restart.
    case connectionNeedsRestart
    /// The selected route cannot securely transfer host files.
    case secureConnectionRequired
    /// The attach credential expired before the file request completed.
    case authenticationExpired
    /// The paired Mac rejected this device's authorization.
    case authorizationFailed
    /// The phone and Mac are signed in to different accounts.
    case accountMismatch
    /// The local device has no remaining space for a temporary file.
    case localStorageFull
    /// The local device could not create or update a temporary file.
    case localStorageUnavailable
    /// A request, authorization, route, stream, or file-handle operation failed
    /// without confirmed closure of the control transport.
    case loadFailed
    /// The control transport to the Mac closed before the request completed.
    case macUnreachable
    /// The file exceeds the inline preview size limit.
    case tooLarge(limitBytes: Int64)
    /// The Mac answered with an error this client does not recognize.
    ///
    /// Distinct from ``macUnreachable``: the connection worked and the Mac
    /// replied, so messaging must not blame connectivity.
    case unknown(code: String?)
}
