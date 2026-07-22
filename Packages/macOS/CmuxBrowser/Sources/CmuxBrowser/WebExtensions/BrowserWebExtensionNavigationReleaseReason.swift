/// Explains why the profile runtime released a navigation intent.
public enum BrowserWebExtensionNavigationReleaseReason: Equatable, Sendable {
    /// Extension registration completed before the deadline.
    case ready

    /// The bounded loading deadline elapsed, so normal browsing continued.
    case deadlineExceeded

    /// Loading completed with a sanitized failure.
    case loadFailed
}
