import Foundation

public extension AuthCoordinator {
    /// The generation of the published account/team scope. It advances when
    /// either the signed-in account or its selected team changes, including a
    /// switch away and back to the same identifiers. Callers pin this value
    /// across an awaited credential read so they cannot pair an old scope with
    /// credentials captured from a newer one.
    var authTeamScopeGeneration: UInt64 { snapshot.teamScopeGeneration }

    /// The locally persisted account and team used only to warm read-only v2
    /// state while Stack validates the session. It is never sufficient for a
    /// server request or a mutation.
    var cachedTeamIdentity: CachedTeamIdentity? {
        snapshot.cachedTeamIdentity.map { CachedTeamIdentity(accountID: $0.accountId, teamID: $0.teamId) }
    }

    /// Current account and selected team, without accessing either credential.
    var authenticatedTeamScope: AuthenticatedTeamScope? { snapshot.teamScope?.scope }

    /// Emits current scope immediately, then account, sign-out and team changes.
    ///
    /// Consumers fence callbacks against ``isAuthenticatedTeamScopeCurrent(_:)``
    /// before installing results; stream consumption itself is asynchronous.
    func authenticatedTeamScopes() -> AsyncStream<AuthenticatedTeamScope?> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            authenticatedTeamScopeContinuations[id] = continuation
            continuation.yield(authenticatedTeamScope)
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.authenticatedTeamScopeContinuations[id] = nil
                }
            }
        }
    }

    /// Returns false synchronously when a captured account or team is replaced.
    func isAuthenticatedTeamScopeCurrent(_ scope: AuthenticatedTeamScope) -> Bool {
        authenticatedTeamScope == scope
    }
}

/// A persisted account/team pair used for local-only startup warming.
public struct CachedTeamIdentity: Sendable, Equatable {
    public let accountID: String
    public let teamID: String

    public init(accountID: String, teamID: String) {
        self.accountID = accountID
        self.teamID = teamID
    }
}

