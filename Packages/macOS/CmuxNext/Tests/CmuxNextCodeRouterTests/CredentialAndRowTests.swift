import Foundation
import Testing
@testable import CmuxNextCodeRouter

@Suite struct CredentialResolverTests {
    @Test func codexCredentialFromAuthJSON() throws {
        let home = try FixtureHome()
        try home.writeJSON(".codex/auth.json", codexAuth())
        let credential = try CredentialResolver(environment: home.environment(), keys: FakeKeyStore()).credential(for: .codex, pasted: nil)
        guard case .codex(let codex) = credential else { Issue.record("expected codex"); return }
        #expect(codex.email == "dev@example.com")
        #expect(codex.body["expiresAt"] as? Double == 1_900_003_600_000)
        #expect(codex.body["accountId"] as? String == "acct-fixture")
        #expect(!"\(codex)".contains("fake-refresh-token"))
    }

    @Test func codexWithoutTokensNeedsReauthentication() throws {
        let home = try FixtureHome()
        try home.writeJSON(".codex/auth.json", ["OPENAI_API_KEY": "sk-fixture"])
        #expect(throws: CredentialResolutionError.incompleteSignIn) {
            _ = try CredentialResolver(environment: home.environment(), keys: FakeKeyStore()).credential(for: .codex, pasted: nil)
        }
    }

    @Test func keyPrecedencePastedThenEnvironmentThenKeychain() throws {
        let home = try FixtureHome()
        let keys = FakeKeyStore([.openRouter: "sk-or-v1-from-keychain-000000"])
        let resolver = CredentialResolver(environment: home.environment(["OPENROUTER_API_KEY": "sk-or-v1-from-env-0000000000"]), keys: keys)
        guard case .apiKey(_, let pasted, _) = try resolver.credential(for: .openRouter, pasted: "sk-or-v1-pasted-00000000000") else { return }
        #expect(pasted == "sk-or-v1-pasted-00000000000")
        guard case .apiKey(_, let env, _) = try resolver.credential(for: .openRouter, pasted: nil) else { return }
        #expect(env == "sk-or-v1-from-env-0000000000")
        let keychainOnly = CredentialResolver(environment: home.environment(), keys: keys)
        guard case .apiKey(_, let stored, _) = try keychainOnly.credential(for: .openRouter, pasted: "  ") else { return }
        #expect(stored == "sk-or-v1-from-keychain-000000")
    }

    @Test func formatsAreChecked() throws {
        let home = try FixtureHome()
        let resolver = CredentialResolver(environment: home.environment(), keys: FakeKeyStore())
        #expect(throws: CredentialResolutionError.needsPastedSecret) { _ = try resolver.credential(for: .claude, pasted: nil) }
        #expect(throws: CredentialResolutionError.invalidFormat) { _ = try resolver.credential(for: .claude, pasted: "sk-ant-api03-wrongkind-0000") }
        #expect(throws: CredentialResolutionError.invalidFormat) { _ = try resolver.credential(for: .anthropic, pasted: "sk-ant-oat01-wrongkind-000") }
        #expect(throws: CredentialResolutionError.unsupported) { _ = try resolver.credential(for: .groq, pasted: "gsk_fixture_00000000000000") }
        #expect(throws: CredentialResolutionError.missingEnvironment("AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY")) {
            _ = try resolver.credential(for: .bedrock, pasted: nil)
        }
    }
}

@Suite struct AccountRowStateTests {
    let codexAccount = LinkedAccount(id: "a1", family: .native, provider: .codex,
                                     account: fixtureLabeler.server(namespace: "codex", id: "a1", label: "dev@example.com"), state: "active")

    func signedInCodex() -> AccountRowState {
        var row = AccountRowState(provider: .codex)
        row.reduce(.cmuxSignIn(true))
        row.reduce(.detected(ProviderDetection(provider: .codex, status: .signedIn)))
        return row
    }

    @Test func startsDetectingThenIdle() {
        var row = AccountRowState(provider: .codex)
        #expect(row.phase == .detecting)
        row.reduce(.detected(ProviderDetection(provider: .claude, status: .signedIn)))
        #expect(row.phase == .detecting, "another provider's result is ignored")
        row.reduce(.detected(.missing(.codex)))
        #expect(row.phase == .idle)
        #expect(row.status == .missing)
    }

    @Test func connectNeedsCmuxSignInAndALocalSignIn() {
        var row = AccountRowState(provider: .codex)
        row.reduce(.detected(ProviderDetection(provider: .codex, status: .signedIn)))
        #expect(!row.canConnect)
        row.reduce(.connectStarted)
        #expect(row.phase == .idle, "Connect is refused while cmux is signed out")
        row.reduce(.cmuxSignIn(true))
        #expect(row.canConnect)
        var missing = AccountRowState(provider: .codex)
        missing.reduce(.cmuxSignIn(true))
        missing.reduce(.detected(.missing(.codex)))
        #expect(!missing.canConnect)
    }

    /// Connect links the account into CodeRouter; while CodeRouter cannot be
    /// reached the button is hidden instead of a line saying why.
    @Test func connectHidesWhileCodeRouterIsUnreachable() {
        var row = AccountRowState(provider: .codex)
        row.reduce(.detected(ProviderDetection(provider: .codex, status: .signedIn)))
        row.reduce(.cmuxSignIn(true))
        #expect(row.canConnect)
        row.reduce(.linkedFailed("Could not connect to the server."))
        #expect(!row.canConnect)
        row.reduce(.linkedLoaded([]))
        #expect(row.canConnect)
    }

    @Test func connectLifecycleAndDuplicateGuard() {
        var row = signedInCodex()
        row.reduce(.connectStarted)
        #expect(row.phase == .connecting)
        row.reduce(.removeStarted(accountID: "a1"))
        #expect(row.phase == .connecting, "one operation at a time")
        row.reduce(.connectSucceeded([codexAccount, LinkedAccount(id: "c", family: .claude, provider: .claude,
                                                                          account: AccountLabel(handle: "acct_c", display: ""), state: "active")]))
        #expect(row.phase == .idle)
        #expect(row.linked == [codexAccount])
        #expect(row.outcome == .connected)
        row.reduce(.connectFailed("late"))
        #expect(row.outcome == .connected, "a stale reply changes nothing")
    }

    @Test func connectFailureKeepsLinks() {
        var row = signedInCodex()
        row.reduce(.linkedLoaded([codexAccount]))
        row.reduce(.connectStarted)
        row.reduce(.connectFailed("Sign in to Codex again before adding this account."))
        #expect(row.outcome == .failed("Sign in to Codex again before adding this account."))
        #expect(row.linked == [codexAccount])
    }

    @Test func removeOnlyKnownAccounts() {
        var row = signedInCodex()
        row.reduce(.removeStarted(accountID: "a1"))
        #expect(row.phase == .idle, "nothing to remove")
        row.reduce(.linkedLoaded([codexAccount]))
        row.reduce(.removeStarted(accountID: "a1"))
        #expect(row.phase == .removing(accountID: "a1"))
        row.reduce(.removeSucceeded([codexAccount]))
        #expect(row.linked.isEmpty, "the removed id is dropped even if the list lags")
        #expect(row.outcome == .removed)
    }

    @Test func reauthReturnsToDetection() {
        var row = signedInCodex()
        row.reduce(.reauthStarted)
        #expect(row.phase == .reauthenticating)
        row.reduce(.reauthEnded)
        #expect(row.phase == .detecting)
        row.reduce(.detected(ProviderDetection(provider: .codex, status: .signedIn,
                                                     account: fixtureLabeler.local(.codex, identity: "new@example.com"))))
        #expect(row.phase == .idle)
        var ollama = AccountRowState(provider: .ollama)
        ollama.reduce(.detected(.missing(.ollama)))
        ollama.reduce(.reauthStarted)
        #expect(ollama.phase == .idle, "a local server has nothing to sign in to")
    }

    @Test func signOutDropsLinks() {
        var row = signedInCodex()
        row.reduce(.linkedLoaded([codexAccount]))
        row.reduce(.cmuxSignIn(false))
        #expect(row.linked.isEmpty)
        #expect(!row.canConnect)
    }

    @Test func pasteRules() {
        var claude = AccountRowState(provider: .claude)
        claude.reduce(.cmuxSignIn(true))
        claude.reduce(.detected(ProviderDetection(provider: .claude, status: .signedIn, sources: [.keychain("Claude Code-credentials")])))
        #expect(claude.canConnect)
        #expect(claude.connectNeedsPaste, "the Keychain sign-in is not sent; a setup-token is pasted")
        var groq = AccountRowState(provider: .groq)
        groq.reduce(.cmuxSignIn(true))
        #expect(!groq.canConnect, "CodeRouter does not route Groq")
    }

    @Test func bedrockConnectNeedsBothAWSKeysInTheEnvironment() throws {
        let home = try FixtureHome()
        try home.write(".aws/config", "[profile work]\nregion = us-east-1\n")
        func row(_ env: [String: String]) -> AccountRowState {
            var row = AccountRowState(provider: .bedrock)
            row.reduce(.cmuxSignIn(true))
            row.reduce(.detected(ProviderDetector(environment: home.environment(env)).detectBedrock()))
            return row
        }
        #expect(row([:]).status == .signedIn)
        #expect(!row([:]).canConnect, "a profile alone cannot be uploaded")
        #expect(!row(["AWS_ACCESS_KEY_ID": "AKIAFIXTURE"]).canConnect)
        #expect(row(["AWS_ACCESS_KEY_ID": "AKIAFIXTURE", "AWS_SECRET_ACCESS_KEY": "fixture"]).canConnect)
    }

    @Test func reauthShellLineQuotes() {
        #expect(AIProvider.codex.reauthPlan.shellLine == "codex login")
        #expect(AIProvider.claude.reauthPlan.shellLine == "claude auth login", "claude auth --help: `auth login`")
        #expect(ReauthPlan.command(["echo", "a b", "it's"]).shellLine == "echo 'a b' 'it'\\''s'")
    }
}
