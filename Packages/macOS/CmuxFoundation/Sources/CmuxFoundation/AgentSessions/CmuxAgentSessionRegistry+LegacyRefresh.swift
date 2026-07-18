extension CmuxAgentSessionRegistry {
    /// The exact durable owner carried by one hibernated panel in an app
    /// snapshot. Session restore uses this context only when a compatibility
    /// sidecar cannot be parsed; normal legacy imports remain authoritative for
    /// generation-zero rows.
    public struct RestoreOwnerContext: Hashable, Sendable {
        public var provider: String
        public var sessionID: String
        public var workspaceID: String
        public var surfaceID: String

        public init(
            provider: String,
            sessionID: String,
            workspaceID: String,
            surfaceID: String
        ) {
            self.provider = provider
            self.sessionID = sessionID
            self.workspaceID = workspaceID
            self.surfaceID = surfaceID
        }
    }

    /// The provider-level outcome of refreshing compatibility JSON before restore.
    public struct LegacyRefreshResult: Equatable, Sendable {
        /// Providers whose changed compatibility JSON was imported successfully.
        public var refreshedProviders: Set<String>

        /// Providers whose ownership state could not be verified from JSON or SQLite.
        public var failedProviders: Set<String>

        /// Exact current-generation owners that remain trustworthy even though
        /// their provider's compatibility sidecar was missing or malformed.
        public var verifiedCanonicalRestoreOwners: Set<RestoreOwnerContext>

        /// Creates a provider-level compatibility refresh outcome.
        ///
        /// - Parameters:
        ///   - refreshedProviders: Providers imported during this refresh.
        ///   - failedProviders: Providers whose ownership state was unavailable or malformed.
        public init(
            refreshedProviders: Set<String>,
            failedProviders: Set<String>,
            verifiedCanonicalRestoreOwners: Set<RestoreOwnerContext> = []
        ) {
            self.refreshedProviders = refreshedProviders
            self.failedProviders = failedProviders
            self.verifiedCanonicalRestoreOwners = verifiedCanonicalRestoreOwners
        }
    }
}
