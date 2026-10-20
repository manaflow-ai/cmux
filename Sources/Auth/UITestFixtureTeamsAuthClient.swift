#if DEBUG
import CMUXAuthCore
import CmuxAuthRuntime
import Foundation

/// UI-test auth client that serves team membership from the launch
/// environment and forwards every session call to the real client.
///
/// Opt-in only: `CMUX_UITEST_AUTH_FIXTURE=1` plus
/// `CMUX_UITEST_AUTH_FIXTURE_TEAMS`, a JSON array of `{"id", "displayName"}`.
/// The first team starts selected so a persisted selection from an earlier
/// run cannot change the starting scope. Optional knobs script the failure
/// and pending paths:
/// `CMUX_UITEST_AUTH_FIXTURE_REJECT_TEAM_NAME` fails creates with that name,
/// `CMUX_UITEST_AUTH_FIXTURE_REJECT_TEAM_ID` fails switches to that team, and
/// `CMUX_UITEST_AUTH_FIXTURE_TEAM_SWITCH_GATE` and
/// `CMUX_UITEST_AUTH_FIXTURE_TEAM_CREATE_GATE` hold each switch or create
/// pending until the test creates a file at that path.
actor UITestFixtureTeamsAuthClient: AuthClient {
    private let base: any AuthClient
    private var teams: [CMUXAuthTeam]
    private var selectedID: String?
    private var createdCount = 0
    private let rejectedCreateName: String?
    private let rejectedSwitchID: String?
    private let switchGate: URL?
    private let createGate: URL?

    /// Returns `base` unchanged unless the launch opted in to fixture teams.
    /// A malformed team list serves no teams rather than the live ones, since
    /// session priming refreshes teams whenever the key is set.
    static func wrapping(_ base: any AuthClient, environment: [String: String]) -> any AuthClient {
        guard environment["CMUX_UITEST_AUTH_FIXTURE"] == "1",
              environment["CMUX_UITEST_CLEAR_AUTH"] != "1",
              let json = environment["CMUX_UITEST_AUTH_FIXTURE_TEAMS"] else {
            return base
        }
        let teams = (try? JSONDecoder().decode([CMUXAuthTeam].self, from: Data(json.utf8))) ?? []
        return UITestFixtureTeamsAuthClient(
            base: base,
            teams: teams,
            rejectedCreateName: environment["CMUX_UITEST_AUTH_FIXTURE_REJECT_TEAM_NAME"],
            rejectedSwitchID: environment["CMUX_UITEST_AUTH_FIXTURE_REJECT_TEAM_ID"],
            switchGate: environment["CMUX_UITEST_AUTH_FIXTURE_TEAM_SWITCH_GATE"].map { URL(fileURLWithPath: $0) },
            createGate: environment["CMUX_UITEST_AUTH_FIXTURE_TEAM_CREATE_GATE"].map { URL(fileURLWithPath: $0) }
        )
    }

    private init(
        base: any AuthClient,
        teams: [CMUXAuthTeam],
        rejectedCreateName: String?,
        rejectedSwitchID: String?,
        switchGate: URL?,
        createGate: URL?
    ) {
        self.base = base
        self.teams = teams
        selectedID = teams.first?.id
        self.rejectedCreateName = rejectedCreateName
        self.rejectedSwitchID = rejectedSwitchID
        self.switchGate = switchGate
        self.createGate = createGate
    }

    func listTeams() async throws -> [CMUXAuthTeam] { teams }

    func selectedTeamID() async throws -> String? { selectedID }

    func setSelectedTeam(id: String?) async throws {
        try await wait(for: switchGate)
        if let id, id == rejectedSwitchID {
            throw AuthClientError.unsupported
        }
        selectedID = id
    }

    func createTeam(displayName: String) async throws -> CMUXAuthTeam {
        try await wait(for: createGate)
        if displayName == rejectedCreateName {
            throw AuthClientError.unsupported
        }
        createdCount += 1
        let team = CMUXAuthTeam(id: "uitest-created-team-\(createdCount)", displayName: displayName)
        teams.append(team)
        return team
    }

    private func wait(for gate: URL?) async throws {
        guard let gate else { return }
        while !FileManager.default.fileExists(atPath: gate.path) {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func accessToken() async -> String? { await base.accessToken() }

    func resolvedAccessToken(forceRefresh: Bool) async throws -> String? {
        try await base.resolvedAccessToken(forceRefresh: forceRefresh)
    }

    func refreshToken() async -> String? { await base.refreshToken() }

    func forceRefreshAccessToken() async -> String? { await base.forceRefreshAccessToken() }

    func currentUser(throwOnMissing: Bool) async throws -> CMUXAuthUser? {
        try await base.currentUser(throwOnMissing: throwOnMissing)
    }

    func sendMagicLinkEmail(email: String, callbackURL: String) async throws -> String {
        try await base.sendMagicLinkEmail(email: email, callbackURL: callbackURL)
    }

    func signInWithMagicLink(code: String) async throws {
        try await base.signInWithMagicLink(code: code)
    }

    func signInWithCredential(email: String, password: String) async throws {
        try await base.signInWithCredential(email: email, password: password)
    }

    func signInWithOAuth(provider: String, anchor: any AuthPresentationAnchoring) async throws {
        try await base.signInWithOAuth(provider: provider, anchor: anchor)
    }

    func storedAccessToken() async -> String? { await base.storedAccessToken() }

    func clearLocalSession() async { await base.clearLocalSession() }

    func clearLocalSession(ifRefreshTokenMatches refreshToken: String) async {
        await base.clearLocalSession(ifRefreshTokenMatches: refreshToken)
    }

    func revokeSession(accessToken: String?, refreshToken: String?) async throws {
        try await base.revokeSession(accessToken: accessToken, refreshToken: refreshToken)
    }

    func freshAccessToken(accessToken: String?, refreshToken: String) async -> String? {
        await base.freshAccessToken(accessToken: accessToken, refreshToken: refreshToken)
    }
}
#endif
