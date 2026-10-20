import CmuxAuthRuntime

/// The parent publishes operation authority only after the original owner subscriptions are checked.
@MainActor
package final class CloudObservedAuthority {
    private let current: @MainActor @Sendable (AuthenticatedSessionIdentity) -> Bool
    private var value: CloudTeamScope.Snapshot?
    private var identity: AuthenticatedSessionIdentity?
    private var epoch: UInt64 = 0

    package init(current: @escaping @MainActor @Sendable (AuthenticatedSessionIdentity) -> Bool) { self.current = current }

    package func bind(_ snapshot: CloudTeamScope.Snapshot, identity: AuthenticatedSessionIdentity) throws {
        guard snapshot.account == identity.accountID, current(identity) else { throw CloudTeamScope.Failure.changed }
        epoch &+= 1
        self.identity = identity; value = wrap(snapshot, epoch: epoch, identity: identity)
    }

    package func clear() { epoch &+= 1; value = nil; identity = nil }

    package func snapshot() throws -> CloudTeamScope.Snapshot {
        guard let identity, current(identity), let value else { throw CloudTeamScope.Failure.unavailable }
        return value
    }

    private func checked<Value: Sendable>(_ epoch: UInt64, identity: AuthenticatedSessionIdentity,
                                         operation: @Sendable () async throws -> Value) async throws -> Value {
        try check(epoch, identity: identity)
        let result = try await operation()
        try check(epoch, identity: identity)
        return result
    }

    private func check(_ epoch: UInt64, identity: AuthenticatedSessionIdentity) throws {
        try Task.checkCancellation()
        guard self.epoch == epoch, self.identity == identity, current(identity) else { throw CloudTeamScope.Failure.changed }
    }

    private func wrap(_ raw: CloudTeamScope.Snapshot, epoch: UInt64, identity: AuthenticatedSessionIdentity) -> CloudTeamScope.Snapshot {
        // Scope IDs are backend retry identities. Observation generations only fence local work.
        CloudTeamScope.Snapshot(id: raw.id, selection: raw.selection, team: raw.team, account: raw.account, generation: raw.generation,
            recheck: { [weak self] in
                guard let self else { throw CloudTeamScope.Failure.changed }
                try await self.checked(epoch, identity: identity, operation: raw.recheck)
            }, installToken: { [weak self] in
                guard let self else { throw CloudTeamScope.Failure.changed }
                return try await self.checked(epoch, identity: identity, operation: raw.installToken)
            }, sessionToken: { [weak self] in
                guard let self else { throw CloudTeamScope.Failure.changed }
                return try await self.checked(epoch, identity: identity, operation: raw.sessionToken)
            }, call: { [weak self] path, body in
                guard let self else { throw CloudTeamScope.Failure.changed }
                return try await self.checked(epoch, identity: identity) { try await raw.call(path, body) }
            }, wireLeases: {
                throw CloudTeamScope.Failure.changed
            }, refreshAuthority: {
                // Only the lifecycle retains raw reconciliation authority; operations cannot publish new scopes.
                throw CloudTeamScope.Failure.changed
            }, reselectAuthority: {
                throw CloudTeamScope.Failure.changed
            }, nativeContext: { [weak self] in
                guard let self else { throw CloudTeamScope.Failure.changed }
                return try await self.checked(epoch, identity: identity, operation: raw.nativeContext)
            }, installGeneration: raw.installGeneration)
    }
}
