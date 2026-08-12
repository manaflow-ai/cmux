/// Typed artifact failures surfaced by chat event sources.
public enum ChatArtifactError: Error, Sendable, Equatable {
    /// The connected Mac or fixture source does not support artifact RPCs.
    case unsupported
    /// The request parameters were malformed.
    case invalidParams
    /// The chat session no longer exists on the Mac.
    case sessionNotFound
    /// The requested path was not referenced by the session.
    case forbidden
    /// The path was in scope but no longer exists on the Mac.
    case fileNotFound
    /// The path is not an image or cannot be decoded as one.
    case unsupportedMedia
    /// The Mac-side artifact service is not wired.
    case unavailable
    /// The Mac could not be reached or did not answer.
    case macUnreachable
    /// The file exceeds the inline preview size limit.
    case tooLarge(limitBytes: Int64)
    /// The Mac answered with an error this client does not recognize.
    ///
    /// Distinct from ``macUnreachable``: the connection worked and the Mac
    /// replied, so messaging must not blame connectivity.
    case unknown(code: String?)
}
