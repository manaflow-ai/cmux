/// Errors produced while creating or hosting a workspace share.
public enum WorkspaceShareError: Error, Equatable, Sendable {
    /// The configured service URL is invalid.
    case invalidServiceURL
    /// The share service returned an unexpected response.
    case invalidResponse
    /// Stack authentication was rejected.
    case unauthorized
    /// The requested share does not exist or expired.
    case unavailable
    /// A transport operation failed.
    case transport(String)

}
