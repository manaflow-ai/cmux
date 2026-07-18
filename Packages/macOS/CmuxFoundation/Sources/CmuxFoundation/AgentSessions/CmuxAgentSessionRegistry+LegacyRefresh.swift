extension CmuxAgentSessionRegistry {
    /// The provider-level outcome of refreshing compatibility JSON before restore.
    public struct LegacyRefreshResult: Equatable, Sendable {
        /// Providers whose changed compatibility JSON was imported successfully.
        public var refreshedProviders: Set<String>

        /// Providers whose ownership state could not be verified from JSON or SQLite.
        public var failedProviders: Set<String>

        /// Creates a provider-level compatibility refresh outcome.
        ///
        /// - Parameters:
        ///   - refreshedProviders: Providers imported during this refresh.
        ///   - failedProviders: Providers whose ownership state was unavailable or malformed.
        public init(
            refreshedProviders: Set<String>,
            failedProviders: Set<String>
        ) {
            self.refreshedProviders = refreshedProviders
            self.failedProviders = failedProviders
        }
    }
}
