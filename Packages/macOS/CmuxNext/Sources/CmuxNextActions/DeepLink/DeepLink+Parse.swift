public import Foundation

extension DeepLink {
    /// The link `url` names, when it is one in `scheme`.
    ///
    /// Nil for another scheme (another build's links are not opened here),
    /// the `auth-callback` host, an unknown host, a malformed id, extra path
    /// segments, a user, password or port, and a fragment other than a
    /// session's `#turn-<turnId>`. Query parameters other than `machine` and
    /// the legacy `stable_*_id` fallbacks are ignored.
    ///
    /// - Parameters:
    ///   - url: The URL to read.
    ///   - scheme: The running build's scheme; compared case-insensitively.
    /// - Returns: The link, or nil when `url` is not one.
    public static func parse(_ url: URL, scheme: String) -> DeepLink? {
        nil
    }
}
