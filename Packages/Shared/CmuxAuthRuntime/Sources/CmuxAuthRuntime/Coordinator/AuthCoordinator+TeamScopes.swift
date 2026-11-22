import Foundation

public extension AuthCoordinator {
    /// The locally persisted account and team used only to warm read-only v2
    /// state while Stack validates the session. It is never sufficient for a
    /// server request or a mutation.
    var cachedTeamIdentity: CachedTeamIdentity? {
        guard sessionCache.hasTokens,
              let accountID = currentUser?.id,
              !accountID.isEmpty,
              let teamID = selectedTeamID,
              !teamID.isEmpty else { return nil }
        return CachedTeamIdentity(accountID: accountID, teamID: teamID)
    }

    /// Current account and selected team, without accessing either credential.
    var authenticatedTeamScope: AuthenticatedTeamScope? {
        guard let session = publishedAuthenticatedSessionIdentity,
              authenticatedTeamsSessionGeneration == session.generation,
              let teamID = resolvedTeamID,
              !teamID.isEmpty,
              availableTeams.contains(where: { $0.id == teamID }) else { return nil }
        return AuthenticatedTeamScope(
            session: session,
            teamID: teamID,
            generation: authenticatedTeamScopeGeneration
        )
    }

    /// Emits current scope immediately, then account, sign-out and team changes.
    ///
    /// Consumers fence callbacks against ``isAuthenticatedTeamScopeCurrent(_:)``
    /// before installing results; stream consumption itself is asynchronous.
    func authenticatedTeamScopes() -> AsyncStream<AuthenticatedTeamScope?> {
        publishAuthenticatedTeamScope()
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

extension AuthCoordinator {
    func publishAuthenticatedTeamScope() {
        let next = authenticatedTeamScope
        let previous = lastPublishedAuthenticatedTeamScope
        guard next?.session != previous?.session || next?.teamID != previous?.teamID else { return }
        authenticatedTeamScopeGeneration &+= 1
        let scope = authenticatedTeamScope
        lastPublishedAuthenticatedTeamScope = scope
        for continuation in authenticatedTeamScopeContinuations.values {
            continuation.yield(scope)
        }
    }
}
