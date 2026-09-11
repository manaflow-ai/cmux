import Foundation

public extension AuthCoordinator {
    /// Current account and selected team, without accessing either credential.
    var authenticatedTeamScope: AuthenticatedTeamScope? {
        guard let session = publishedAuthenticatedSessionIdentity,
              let teamID = resolvedTeamID,
              !teamID.isEmpty else { return nil }
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
