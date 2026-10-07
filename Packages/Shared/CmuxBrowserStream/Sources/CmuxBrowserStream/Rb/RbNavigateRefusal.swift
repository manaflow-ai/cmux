/// Why the host refused `rb.navigate`.
public enum RbNavigateRefusal: String, Hashable, Sendable, CaseIterable {
    /// Not an http or https URL.
    case scheme
    /// Not a URL, or no host.
    case invalid
    /// The device's session gate is closed (revoked).
    case notAllowed = "not_allowed"
    /// The page owner failed to start the load.
    case failed
}
