/// Describes how browser user-agent policy applies to a top-level destination.
public enum BrowserUserAgentPolicyResolution: Equatable, Sendable {
    /// Use the supplied custom user-agent identity for an HTTP or HTTPS destination.
    case custom(String)

    /// User-agent identity does not apply to this non-web destination.
    case notApplicable
}
