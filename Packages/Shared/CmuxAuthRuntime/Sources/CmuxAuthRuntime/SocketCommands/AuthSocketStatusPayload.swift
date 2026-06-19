import CMUXAuthCore

/// The typed result payload for `auth.status`, `auth.begin_sign_in`, and `auth.sign_out`.
public struct AuthSocketStatusPayload: Sendable, Equatable {
    /// Whether a user session is currently active.
    public let signedIn: Bool
    /// Whether launch session restore is still running.
    public let isRestoringSession: Bool
    /// Whether auth UI or network work is in flight.
    public let isLoading: Bool
    /// Whether the caller's bounded wait timed out.
    public let timedOut: Bool
    /// The signed-in user, if any.
    public let user: AuthSocketUserPayload?
    /// The team id API calls should target, if any.
    public let selectedTeamID: String?
    /// The teams the signed-in user belongs to.
    public let teams: [AuthSocketTeamPayload]

    /// Creates an auth status payload.
    ///
    /// - Parameters:
    ///   - signedIn: Whether a user session is currently active.
    ///   - isRestoringSession: Whether launch session restore is still running.
    ///   - isLoading: Whether auth UI or network work is in flight.
    ///   - timedOut: Whether the caller's bounded wait timed out.
    ///   - user: The signed-in user, if any.
    ///   - selectedTeamID: The team id API calls should target, if any.
    ///   - teams: The teams the signed-in user belongs to.
    public init(
        signedIn: Bool,
        isRestoringSession: Bool,
        isLoading: Bool,
        timedOut: Bool,
        user: AuthSocketUserPayload? = nil,
        selectedTeamID: String? = nil,
        teams: [AuthSocketTeamPayload] = []
    ) {
        self.signedIn = signedIn
        self.isRestoringSession = isRestoringSession
        self.isLoading = isLoading
        self.timedOut = timedOut
        self.user = user
        self.selectedTeamID = selectedTeamID
        self.teams = teams
    }

    @MainActor
    init(coordinator: AuthCoordinator?, isSigningIn: Bool, timedOut: Bool) {
        guard let coordinator else {
            self.init(
                signedIn: false,
                isRestoringSession: false,
                isLoading: false,
                timedOut: timedOut
            )
            return
        }
        self.init(
            signedIn: coordinator.isAuthenticated,
            isRestoringSession: coordinator.isRestoringSession,
            isLoading: coordinator.isLoading || isSigningIn,
            timedOut: timedOut,
            user: coordinator.currentUser.map(AuthSocketUserPayload.init(user:)),
            selectedTeamID: coordinator.resolvedTeamID,
            teams: coordinator.availableTeams.map(AuthSocketTeamPayload.init(team:))
        )
    }
}

private extension AuthSocketUserPayload {
    init(user: CMUXAuthUser) {
        self.init(id: user.id, email: user.primaryEmail, displayName: user.displayName)
    }
}

private extension AuthSocketTeamPayload {
    init(team: CMUXAuthTeam) {
        self.init(id: team.id, displayName: team.displayName, slug: team.slug)
    }
}
