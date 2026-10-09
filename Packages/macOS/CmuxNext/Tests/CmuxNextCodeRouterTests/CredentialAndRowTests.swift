import Foundation
import Testing
@testable import CmuxNextCodeRouter

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
