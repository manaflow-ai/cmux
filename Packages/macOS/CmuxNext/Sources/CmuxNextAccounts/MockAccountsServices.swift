public import CmuxNextCodeRouter
public import CmuxNextCloud
public import Foundation
public import Observation

/// Sample data for the demo and tests: a signed-in Codex and Claude Code,
/// one env key, Ollama running, and one CodeRouter account. Records calls.
@MainActor @Observable
public final class MockAccountsServices: AccountsServices {
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
    public var linked: [LinkedAccount] = [
        LinkedAccount(id: "11111111-1111-4111-8111-111111111111", family: .native, provider: .codex,
                      account: AccountLabel.demo("codex", display: "d…@e…"), state: "active"),
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
    public var failure: (any Error)?
    /// Fails only the account list (CodeRouter answered the add or remove, then not the reload).
    public var linkedFailure: (any Error)?
    /// False: no local pane, so a login or logout opens nothing.
    public var opensTabs = true
    public private(set) var calls: [String] = []

    public init() {
        team = ActiveTeam(source: teamSource)
    }

    public func detect() async -> [ProviderDetection] {
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

    public func linkedAccounts() async throws -> [LinkedAccount] {
        calls.append("linked")
        if let failure = failure ?? linkedFailure { throw failure }
        return linked
    }

    public func connect(_ provider: AIProvider, pasted: String?) async throws {
        calls.append("connect:\(provider.rawValue):\(pasted == nil ? "local" : "pasted")")
        if let failure { throw failure }
        let id = UUID().uuidString.lowercased()
        let family: LinkedAccount.Family = [.claude, .anthropic, .bedrock].contains(provider) ? .claude : .native
        linked.append(LinkedAccount(id: id, family: family, provider: provider,
                                    account: AccountLabel.demo(provider.rawValue, display: provider.displayName), state: "active"))
    }

    public func remove(_ account: LinkedAccount) async throws {
        calls.append("remove:\(account.id)")
        if let failure { throw failure }
        linked.removeAll { $0.id == account.id }
    }

    @discardableResult
    public func reauthenticate(_ provider: AIProvider, plan: ReauthPlan) -> Bool {
        calls.append(plan == provider.signOutPlan ? "signOut:\(provider.rawValue)" : "reauth:\(provider.rawValue)")
        return opensTabs
    }

    public func runClaudeSetupToken() { calls.append("setupToken") }
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
