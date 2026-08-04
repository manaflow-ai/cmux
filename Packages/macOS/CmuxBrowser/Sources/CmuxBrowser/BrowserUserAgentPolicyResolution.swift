/// Describes how browser user-agent policy applies to a top-level destination.
public enum BrowserUserAgentPolicyResolution: Equatable, Sendable {
    /// Use the supplied custom user-agent identity for an HTTP or HTTPS destination.
    case custom(String)

    /// Keep WebKit's embedded identity while advertising a supported identity
    /// on the top-level HTTP request.
    case webKitDefault(topLevelRequestUserAgent: String)

    /// User-agent identity does not apply to this non-web destination.
    case notApplicable
}
