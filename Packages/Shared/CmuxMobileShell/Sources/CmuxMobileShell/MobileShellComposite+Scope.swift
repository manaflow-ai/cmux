import Foundation

@MainActor
extension MobileShellComposite {
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
        return MobileShellScopeSnapshot(
            userID: userID,
            teamID: await teamIDProvider(),
            generation: secondaryAggregationScopeGeneration
        )
    }

    func pairedMacScopeKey(_ scope: MobileShellScopeSnapshot) -> String {
        makePairedMacScopeKey(userID: scope.userID, teamID: scope.teamID)
    }

    func makePairedMacScopeKey(userID: String, teamID: String?) -> String {
        "\(userID)\t\(teamID ?? "")"
    }

    func userWideScope(from scope: MobileShellScopeSnapshot) -> MobileShellScopeSnapshot {
        MobileShellScopeSnapshot(userID: scope.userID, teamID: nil, generation: scope.generation)
    }

    /// Whether a previously-captured list-load scope is still current.
    func isScopeCurrent(_ scope: MobileShellScopeSnapshot) async -> Bool {
        guard isSignedIn,
              secondaryAggregationScopeGeneration == scope.generation else {
            return false
        }
        if let currentUserID = identityProvider?.currentUserID,
           currentUserID != scope.userID {
            return false
        }
        return await teamIDProvider() == scope.teamID
    }
}
