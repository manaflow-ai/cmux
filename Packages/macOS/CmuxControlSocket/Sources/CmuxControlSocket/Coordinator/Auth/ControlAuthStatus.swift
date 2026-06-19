/// A typed, `Sendable` snapshot of the live auth state the `auth.status` /
/// `auth.begin_sign_in` / `auth.sign_out` payloads report.
///
/// Read off the auth coordinator (and the browser sign-in flow's "is signing
/// in" flag) on the main actor through ``AuthStatusReading``, then encoded onto
/// the wire by ``ControlAuthWorker`` exactly as the legacy `v2AuthStatusPayload`
/// did. The `timed_out` wire field is NOT part of this snapshot: it is supplied
/// per-command by the worker (`false` for `auth.status` / `auth.sign_out`, and
/// the negation of the sign-in result for `auth.begin_sign_in`), matching the
/// legacy `timedOut:` parameter.
///
/// The coordinator-absent case is represented by ``AuthStatusReading``'s seam
/// returning `nil`, which the worker renders as the fixed "not signed in"
/// payload the legacy code produced when `authCoordinator` was `nil`.
public struct ControlAuthStatus: Sendable, Equatable {
    /// Whether a user session is active (wire key `signed_in`, from
    /// `coordinator.isAuthenticated`).
    public let signedIn: Bool
    /// Whether a cached session is being restored/validated (wire key
    /// `is_restoring_session`, from `coordinator.isRestoringSession`).
    public let isRestoringSession: Bool
    /// Whether a load or interactive sign-in is in flight (wire key
    /// `is_loading`, the legacy `coordinator.isLoading || isSigningIn`).
    public let isLoading: Bool
    /// The signed-in user, or `nil` to omit the wire `user` object.
    public let user: ControlAuthUser?
    /// The resolved selected team id, or `nil` to omit the wire
    /// `selected_team_id` key.
    public let selectedTeamID: String?
    /// The user's teams. Omitted from the wire (`teams` key absent) when empty,
    /// matching the legacy `!availableTeams.isEmpty` guard.
    public let teams: [ControlAuthTeam]

    /// Creates an auth status snapshot.
    ///
    /// - Parameters:
    ///   - signedIn: Whether a session is active.
    ///   - isRestoringSession: Whether a cached session is being restored.
    ///   - isLoading: Whether a load or sign-in is in flight.
    ///   - user: The signed-in user, or `nil`.
    ///   - selectedTeamID: The resolved selected team id, or `nil`.
    ///   - teams: The user's teams (empty omits the wire key).
    public init(
        signedIn: Bool,
        isRestoringSession: Bool,
        isLoading: Bool,
        user: ControlAuthUser?,
        selectedTeamID: String?,
        teams: [ControlAuthTeam]
    ) {
        self.signedIn = signedIn
        self.isRestoringSession = isRestoringSession
        self.isLoading = isLoading
        self.user = user
        self.selectedTeamID = selectedTeamID
        self.teams = teams
    }
}
