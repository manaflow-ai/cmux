extension CmuxAgentSessionRegistry {
    /// Aggregate compatibility bytes one refresh call may open. Individual
    /// sources keep the same 64 MiB ceiling, while a many-provider restore can
    /// no longer retain or scan that ceiling once per configured adapter.
    public static let maximumLegacyRefreshReadBytes: Int64 = 64 * 1_024 * 1_024

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

        /// Providers skipped before opening their changed compatibility source
        /// because its stamped size did not fit the remaining aggregate budget.
        /// These providers are also present in `failedProviders`.
        public var readBudgetExceededProviders: Set<String>

        /// A conservative upper bound on bytes opened by this refresh. Each
        /// attempted revision reserves its stamped size before the descriptor
        /// is opened, including malformed or concurrently replaced revisions.
        public var sourceReadBudgetUsed: Int64

        /// Exact current-generation owners that remain trustworthy even though
        /// their provider's compatibility sidecar was missing or malformed.
        public var verifiedCanonicalRestoreOwners: Set<RestoreOwnerContext>

        /// Creates a provider-level compatibility refresh outcome.
        ///
        /// - Parameters:
        ///   - refreshedProviders: Providers imported during this refresh.
        ///   - failedProviders: Providers whose ownership state was unavailable or malformed.
        ///   - readBudgetExceededProviders: Providers skipped by the aggregate read budget.
        ///   - sourceReadBudgetUsed: Stamped bytes reserved by attempted source reads.
        public init(
            refreshedProviders: Set<String>,
            failedProviders: Set<String>,
            readBudgetExceededProviders: Set<String> = [],
            sourceReadBudgetUsed: Int64 = 0,
            verifiedCanonicalRestoreOwners: Set<RestoreOwnerContext> = []
        ) {
            self.refreshedProviders = refreshedProviders
            self.failedProviders = failedProviders
            self.readBudgetExceededProviders = readBudgetExceededProviders
            self.sourceReadBudgetUsed = sourceReadBudgetUsed
            self.verifiedCanonicalRestoreOwners = verifiedCanonicalRestoreOwners
        }
    }
}
