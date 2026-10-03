public import CmuxNextCodeRouter
public import Foundation

/// Sample data for the demo and tests: a signed-in Codex and Claude Code,
/// one env key, Ollama running, and one CodeRouter account. Records calls.
@MainActor
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
    public var failure: (any Error)?
    public private(set) var calls: [String] = []

    public init() {}

    public func detect() async -> [ProviderDetection] {
        calls.append("detect")
        let found = Dictionary(uniqueKeysWithValues: detections.map { ($0.provider, $0) })
        return AIProvider.allCases.map { found[$0] ?? .missing($0) }
    }

    public func signInToCmux() {
        calls.append("signIn")
        isSignedInToCmux = true
    }

    public func linkedAccounts() async throws -> [LinkedAccount] {
        calls.append("linked")
        if let failure { throw failure }
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

    public func reauthenticate(_ provider: AIProvider, plan: ReauthPlan) {
        calls.append("reauth:\(provider.rawValue)")
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
