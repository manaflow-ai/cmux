public enum CloudOpsError: Error, Hashable, Sendable {
    /// No install principal on this device yet.
    case installTokenUnavailable
    /// HTTP-level refusal (auth, redirect, server error).
    case httpStatus(Int)
    /// The owner refused the op (`ok: false`).
    case rejected(code: String, retryable: Bool)
    case transport
    /// No valid API Worker origin is configured: nothing is sent.
    case notConfigured
}
