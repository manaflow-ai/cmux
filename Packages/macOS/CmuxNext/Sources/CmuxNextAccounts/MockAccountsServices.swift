public import CMUXAuthCore
public import CmuxNextCodeRouter
public import CmuxNextCloud
public import Foundation
public import Observation

/// Sample data for the demo and tests: a signed-in Codex and Claude Code,
/// one env key and Ollama running. Records calls.
@MainActor @Observable
public final class MockAccountsServices: AccountsServices, AccountsTeamBackend {
    public var detections: [ProviderDetection] = [
        ProviderDetection(provider: .codex, status: .signedIn, account: AccountLabel.demo("codex", display: "pro"), plan: "pro",
                          sources: [.file("~/.codex/auth.json")]),
        ProviderDetection(provider: .claude, status: .signedIn, account: AccountLabel.demo("claude", display: "d…@e…"),
                          sources: [.keychain("Claude Code-credentials")]),
        ProviderDetection(provider: .anthropic, status: .signedIn, sources: [.environment("ANTHROPIC_API_KEY")]),
        ProviderDetection(provider: .gemini, status: .expired, account: AccountLabel.demo("gemini", display: "d…@g…"),
                          sources: [.file("~/.gemini/oauth_creds.json")]),
        ProviderDetection(provider: .ollama, status: .signedIn, detail: "127.0.0.1:11434", sources: [.server("127.0.0.1:11434")]),
    ]
    public var isSignedInToCmux = true
    @ObservationIgnored private let teamSource = MockTeamSource()
    @ObservationIgnored private let team: ActiveTeam
    public var activeTeam: ActiveTeam? { isSignedInToCmux ? team : nil }
    /// What the next team switch throws, if anything.
    public var teamFailure: (any Error)? {
        get { teamSource.failure }
        set { teamSource.failure = newValue }
    }
    /// What the next team create, rename, delete or detail read throws, if anything.
    public var teamManagementFailure: (any Error)? {
        get { teamSource.managementFailure }
        set { teamSource.managementFailure = newValue }
    }
    /// The teams the demo person administers (the others they are a member of).
    public var adminTeamIDs: Set<String> {
        get { teamSource.adminTeams }
        set { teamSource.adminTeams = newValue }
    }
    /// Invitations addressed to the demo person.
    public var receivedInvitations: [CMUXReceivedTeamInvitation] {
        get { teamSource.received }
        set { teamSource.received = newValue }
    }
    /// Teams with an active subscription: deleting one is refused.
    public var subscribedTeamIDs: Set<String> {
        get { teamSource.subscribedTeams }
        set { teamSource.subscribedTeams = newValue }
    }
    /// Member teams whose members hold update, delete and invite permissions (still not admins).
    public var permissiveMemberTeamIDs: Set<String> {
        get { teamSource.permissiveMemberTeams }
        set { teamSource.permissiveMemberTeams = newValue }
    }
    /// Answer memberships without roles, as the sign-in service alone does.
    public var rolesUnknown = false
    public var failure: (any Error)?
    /// Fails only the account list (CodeRouter answered the add or remove, then not the reload).
    /// False: no local pane, so a login or logout opens nothing.
    public var opensTabs = true
    /// Optional async tab opener for exercising delayed workspace creation.
    @ObservationIgnored public var openProviderTab: ((ReauthPlan) async -> Bool)?
    /// Optional gate before a detection result is produced. Tests use this to
    /// reproduce a refresh completing after a local login has started.
    @ObservationIgnored public var beforeDetect: (() async -> Void)?
    public private(set) var calls: [String] = []

    public init() {
        team = ActiveTeam(source: teamSource)
    }

    public func detect() async -> [ProviderDetection] {
        if let beforeDetect { await beforeDetect() }
        calls.append("detect")
        let found = Dictionary(uniqueKeysWithValues: detections.map { ($0.provider, $0) })
        return AIProvider.allCases.map { found[$0] ?? .missing($0) }
    }

    public func signInToCmux() {
        calls.append("signIn")
        isSignedInToCmux = true
    }

    /// What cmux's row shows while signed out (a sign-in in progress, a failure).
    public var cmuxSignInState = CmuxAccountState.signedOut
    public var cmuxAccount: CmuxAccountState {
        var account = cmuxSignInState
        if isSignedInToCmux { account.signedIn = true; account.label = "d…@e…" }
        return account
    }

    public func runCmuxAccount(_ action: CmuxAccountAction) {
        calls.append("cmux:\(action.rawValue)")
        switch action {
        case .signIn, .switchAccount: signInToCmux()
        case .signOut: isSignedInToCmux = false
        case .cancelSignIn: cmuxSignInState = .signedOut
        case .continueInBrowser: break
        }
    }

    public var teamBackend: (any AccountsTeamBackend)? { self }

    public func teamMemberships() async throws -> CMUXTeamMemberships {
        calls.append("teams")
        let list = teamSource.memberships
        guard rolesUnknown else { return list }
        return CMUXTeamMemberships(teams: list.teams.map { CMUXTeamMembership(team: $0.team) }, selectedTeamID: list.selectedTeamID)
    }

    public func teamDetail(id: String) async throws -> CMUXTeamDetail {
        calls.append("team:\(id)")
        return try teamSource.detail(id: id)
    }

    public func createTeam(named name: String) async throws -> CMUXAuthTeam {
        calls.append("createTeam")
        return try teamSource.create(name)
    }

    public func renameTeam(id: String, to name: String) async throws {
        calls.append("renameTeam:\(id)")
        try teamSource.rename(id, to: name)
    }

    public func deleteTeam(id: String) async throws {
        calls.append("deleteTeam:\(id)")
        try teamSource.delete(id)
    }

    public func receivedTeamInvitations() async throws -> [CMUXReceivedTeamInvitation] {
        calls.append("receivedInvitations")
        if let failure = teamSource.managementFailure { throw failure }
        return teamSource.received
    }

    @discardableResult
    public func acceptTeamInvitation(id: String) async throws -> CMUXTeamJoin {
        calls.append("acceptInvitation:\(id)")
        return try teamSource.accept(id)
    }

    public func declineTeamInvitation(id: String) async throws {
        calls.append("declineInvitation:\(id)")
        try teamSource.decline(id)
    }

    @discardableResult
    public func reauthenticate(_ provider: AIProvider, plan: ReauthPlan) async -> Bool {
        calls.append(plan == provider.signOutPlan ? "signOut:\(provider.rawValue)" : "reauth:\(provider.rawValue)")
        if let openProviderTab { return await openProviderTab(plan) }
        return opensTabs
    }

    public func openConsole(_ url: URL) { calls.append("console") }

    public func saveKey(_ key: String, for provider: AIProvider) throws {
        calls.append("saveKey:\(provider.rawValue)")
        detections.removeAll { $0.provider == provider }
        detections.append(ProviderDetection(provider: provider, status: .signedIn, sources: [.cmuxKeychain]))
    }

    public func deleteSavedKey(for provider: AIProvider) throws {
        calls.append("deleteKey:\(provider.rawValue)")
        detections.removeAll { $0.provider == provider }
    }
}
