import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation

@MainActor
extension MobileShellComposite {
    /// Resets the complete shell boundary if Stack replaces A with B without a signed-out edge.
    func prepareRPCAuthForSignIn() -> Bool {
        let currentUserID = identityProvider?.currentUserID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUserID = currentUserID?.isEmpty == false ? currentUserID : nil
        let replacedAuthenticatedUser = isSignedIn && rpcAuthStackUserID != normalizedUserID
        if replacedAuthenticatedUser {
            signOut()
        }
        rpcAuthStackUserID = normalizedUserID
        return replacedAuthenticatedUser
    }

    func rotateRPCAuthScope() {
        cancelManualHostTrustExpiration()
        let invalidatedScopes = [rpcAuthScope, manualHostRPCAuthScope]
        for scope in invalidatedScopes { scope.revoke() }
        rpcAuthScope = MobileRPCAuthScope()
        manualHostRPCAuthScope = MobileRPCAuthScope()
        let tokenGate = stackTokenGate
        let forceRefreshGate = stackTokenForceRefreshGate
        Task {
            for scope in invalidatedScopes {
                await tokenGate.invalidate(scope: scope)
                await forceRefreshGate.invalidate(scope: scope)
            }
        }
    }

    /// Invalidates only plaintext manual-host credentials after a network-path change.
    func rotateManualHostRPCAuthScope() {
        cancelManualHostTrustExpiration()
        let invalidatedScope = manualHostRPCAuthScope
        invalidatedScope.revoke()
        manualHostRPCAuthScope = MobileRPCAuthScope()
        let tokenGate = stackTokenGate
        let forceRefreshGate = stackTokenForceRefreshGate
        Task {
            await tokenGate.invalidate(scope: invalidatedScope)
            await forceRefreshGate.invalidate(scope: invalidatedScope)
        }
    }

    func currentRPCAuthContext() -> MobileShellRPCAuthContext {
        MobileShellRPCAuthContext(
            stackUserID: identityProvider?.currentUserID,
            accountScope: rpcAuthScope,
            manualHostScope: manualHostRPCAuthScope
        )
    }

    func isRPCAuthContextCurrent(
        _ context: MobileShellRPCAuthContext,
        requiresManualHostScope: Bool = true
    ) -> Bool {
        guard isSignedIn,
              identityProvider?.currentUserID == context.stackUserID,
              rpcAuthScope == context.accountScope else {
            return false
        }
        return !requiresManualHostScope || manualHostRPCAuthScope == context.manualHostScope
    }

    func rpcAuthScopeForRoute(
        for route: CmxAttachRoute,
        context: MobileShellRPCAuthContext
    ) -> MobileRPCAuthScope {
        MobileShellRouteAuthPolicy().routeRequiresManualHostTrust(route)
            ? context.manualHostScope
            : context.accountScope
    }

    func rpcAuthScopeValidator(
        for route: CmxAttachRoute,
        context: MobileShellRPCAuthContext
    ) -> @Sendable () async -> Bool {
        let requiresManualHostScope = MobileShellRouteAuthPolicy().routeRequiresManualHostTrust(route)
        return { [weak self] in
            guard let self else { return false }
            return await self.isRPCAuthContextCurrent(
                context,
                requiresManualHostScope: requiresManualHostScope
            )
        }
    }

    /// Capture the current signed-in account/team scope for async list loads and
    /// route writes.
    func currentScopeSnapshot(userID explicitUserID: String? = nil) async -> MobileShellScopeSnapshot? {
        guard isSignedIn,
              let userID = explicitUserID ?? identityProvider?.currentUserID,
              !userID.isEmpty else {
            return nil
        }
        if let currentUserID = identityProvider?.currentUserID,
           currentUserID != userID {
            return nil
        }
        let generation = secondaryAggregationScopeGeneration
        let signInGeneration = currentSessionGeneration
        let rpcAuthContext = currentRPCAuthContext()
        let teamID = await teamIDProvider()
        guard isSignedIn,
              identityProvider?.currentUserID == userID,
              generation == secondaryAggregationScopeGeneration,
              signInGeneration == currentSessionGeneration,
              isRPCAuthContextCurrent(rpcAuthContext) else {
            return nil
        }
        return MobileShellScopeSnapshot(
            userID: userID,
            teamID: teamID,
            generation: generation,
            signInGeneration: signInGeneration,
            rpcAuthContext: rpcAuthContext
        )
    }

    func pairedMacScopeKey(_ scope: MobileShellScopeSnapshot) -> String {
        makePairedMacScopeKey(userID: scope.userID, teamID: scope.teamID)
    }

    func makePairedMacScopeKey(userID: String, teamID: String?) -> String {
        "\(userID)\t\(teamID ?? "")"
    }

    func userWideScope(from scope: MobileShellScopeSnapshot) -> MobileShellScopeSnapshot {
        MobileShellScopeSnapshot(
            userID: scope.userID,
            teamID: nil,
            generation: scope.generation,
            signInGeneration: scope.signInGeneration,
            rpcAuthContext: scope.rpcAuthContext
        )
    }

    /// Whether a previously-captured list-load scope is still current.
    func isScopeCurrent(_ scope: MobileShellScopeSnapshot) async -> Bool {
        guard isSignedIn,
              secondaryAggregationScopeGeneration == scope.generation,
              currentSessionGeneration == scope.signInGeneration,
              isRPCAuthContextCurrent(scope.rpcAuthContext) else {
            return false
        }
        if let currentUserID = identityProvider?.currentUserID,
           currentUserID != scope.userID {
            return false
        }
        return await teamIDProvider() == scope.teamID
    }

}
