/// Validates the identity fields for a tagged Debug cmux server.
public struct CodeRouterDebugServerIdentityPolicy {
    /// Creates a Debug server identity policy.
    public init() {}

    /// Tests whether the signing fields match the expected tagged cmux build.
    ///
    /// - Parameters:
    ///   - identifier: The connected server's code-signing identifier.
    ///   - teamIdentifier: The connected server's signing team.
    ///   - expectedBundleIdentifier: The tagged bundle identifier selected by
    ///     the CLI environment.
    /// - Returns: `true` only for the exact expected company-signed Debug app.
    public func isAllowed(
        identifier: String?,
        teamIdentifier: String?,
        expectedBundleIdentifier: String?
    ) -> Bool {
        let taggedPrefix = "com.cmuxterm.app.debug."
        guard let expectedBundleIdentifier,
              expectedBundleIdentifier.hasPrefix(taggedPrefix),
              expectedBundleIdentifier.count > taggedPrefix.count,
              identifier == expectedBundleIdentifier,
              teamIdentifier == "7WLXT3NR37" else {
            return false
        }
        return true
    }
}
