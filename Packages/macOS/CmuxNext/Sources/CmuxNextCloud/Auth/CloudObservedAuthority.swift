package import CmuxAuthRuntime

/// The parent publishes operation authority only after the original owner subscriptions are checked.
@MainActor
package final class CloudObservedAuthority {
    private let current: @MainActor @Sendable (AuthenticatedSessionIdentity) -> Bool
    private var value: CloudTeamScope.Snapshot?
    private var identity: AuthenticatedSessionIdentity?

    package init(current: @escaping @MainActor @Sendable (AuthenticatedSessionIdentity) -> Bool) { self.current = current }

    package func bind(_ snapshot: CloudTeamScope.Snapshot, identity: AuthenticatedSessionIdentity) throws {
        guard snapshot.account == identity.accountID, current(identity) else { throw CloudTeamScope.Failure.changed }
        self.identity = identity; value = snapshot
    }

    package func clear() { value = nil; identity = nil }

    package func snapshot() throws -> CloudTeamScope.Snapshot {
        guard let identity, current(identity), let value else { throw CloudTeamScope.Failure.unavailable }
        return value
    }
}
