public import Foundation

/// One immutable projection of everything cmux knows about the subrouter
/// daemon: reachability, accounts with usage, and session pins.
///
/// Views receive this value (never the store) below list boundaries, per the
/// sidebar snapshot-boundary rule.
public struct SubrouterSnapshot: Sendable, Equatable {
    /// An empty snapshot (state before the first refresh).
    public static let empty = SubrouterSnapshot()

    /// The daemon's reachability.
    public var daemonState: SubrouterDaemonState
    /// All accounts with usage detail, in daemon order.
    public var usageStatuses: [SubrouterAccountUsageStatus]
    /// Live agent-session → account pins, in daemon order.
    public var sessions: [SubrouterSessionAssignment]
    /// When the last successful refresh completed, or `nil` before one.
    public var lastUpdatedAt: Date?
    /// A short description of the last refresh failure, or `nil`.
    public var lastErrorDescription: String?

    /// Creates a snapshot.
    /// - Parameters:
    ///   - daemonState: The daemon's reachability.
    ///   - usageStatuses: Accounts with usage detail.
    ///   - sessions: Session pins.
    ///   - lastUpdatedAt: When the last successful refresh completed.
    ///   - lastErrorDescription: The last refresh failure, if any.
    public init(
        daemonState: SubrouterDaemonState = .unknown,
        usageStatuses: [SubrouterAccountUsageStatus] = [],
        sessions: [SubrouterSessionAssignment] = [],
        lastUpdatedAt: Date? = nil,
        lastErrorDescription: String? = nil
    ) {
        self.daemonState = daemonState
        self.usageStatuses = usageStatuses
        self.sessions = sessions
        self.lastUpdatedAt = lastUpdatedAt
        self.lastErrorDescription = lastErrorDescription
    }
}

extension SubrouterSnapshot {
    /// The providers present in ``usageStatuses``, Codex first, then Claude,
    /// then any unknown providers in order of first appearance.
    public var providers: [SubrouterProvider] {
        var seen = Set<SubrouterProvider>()
        var ordered: [SubrouterProvider] = []
        for known in [SubrouterProvider.codex, .claude] where usageStatuses.contains(where: { $0.provider == known }) {
            seen.insert(known)
            ordered.append(known)
        }
        for status in usageStatuses where !seen.contains(status.provider) {
            seen.insert(status.provider)
            ordered.append(status.provider)
        }
        return ordered
    }

    /// The accounts for one provider, in daemon order.
    /// - Parameter provider: The provider to filter by.
    public func accounts(for provider: SubrouterProvider) -> [SubrouterAccountUsageStatus] {
        usageStatuses.filter { $0.provider == provider }
    }

    /// The provider's active account, if the daemon reported one.
    /// - Parameter provider: The provider to look up.
    public func activeAccount(for provider: SubrouterProvider) -> SubrouterAccountUsageStatus? {
        usageStatuses.first { $0.provider == provider && $0.isActive }
    }

    /// How many providers' active accounts currently need attention (cooked,
    /// temp-cooked, nearly exhausted, or failing auth). Drives the mode-bar
    /// badge and the footer status dot.
    public var attentionCount: Int {
        providers.reduce(into: 0) { count, provider in
            if let active = activeAccount(for: provider), active.needsAttention {
                count += 1
            }
        }
    }

    /// The session pins routed to one account, newest update first.
    /// - Parameter accountID: The account id to filter by.
    public func sessions(forAccountID accountID: String) -> [SubrouterSessionAssignment] {
        sessions
            .filter { $0.accountID == accountID }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}
