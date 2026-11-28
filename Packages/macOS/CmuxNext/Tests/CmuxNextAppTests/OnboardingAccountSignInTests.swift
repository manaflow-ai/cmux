@testable import CmuxNextAccounts
@testable import CmuxNextAgentPane
@testable import CmuxNextOnboarding
import CmuxNextPages
import CmuxNextSettings
import Foundation
import os
import Testing

/// The Agents step's in-place sign-in (logins done right): `signInAccounts` and `signInReadiness` in
/// the onboarding state from the daemon, `cmux.onboarding.accounts.run` through Settings > Accounts'
/// own forwarder, and a daemon without `_acpmux/account/readiness` leaving onboarding as before.
@MainActor @Suite(.serialized) struct OnboardingAccountSignInTests {
    @MainActor final class Recorder {
        var opened: [URL] = []
        var readinessReads = 0
    }

    private nonisolated static let accountsReply = Data("""
    {"accounts":[
      {"id":"codex-login","family":"codex","name":"ChatGPT","home":null,"signedIn":false,"enabled":true,
       "builtin":true,"default":true},
      {"id":"github:alex","family":"github","name":"alex","signedIn":true,"default":true,"builtin":false}
    ]}
    """.utf8)

    private nonisolated static let readinessReply = Data("""
    {"providers":[{"family":"github","state":"ready","account":"alex"},
      {"family":"codex","state":"signInRequired","label":"ChatGPT"},{"family":"claude","state":"notInstalled"}]}
    """.utf8)

    private nonisolated static let start = Data("""
    {"account":"codex-login","loginId":"login-9","url":"https://auth.openai.com/codex/device","userCode":"WXYZ-9876",
     "needsCode":false,"expiresAtMs":4102444800000,"added":false}
    """.utf8)

    /// `readiness`: false answers method-not-found for `_acpmux/account/readiness` (an older daemon).
    private func make(readiness: Bool = true) -> (harnesses: SettingsHarnesses, recorder: Recorder, signIn: OnboardingSignIn) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cn-onboarding-sign-in-\(UUID().uuidString)")
        let environment = AcpmuxEnvironment(executable: directory.appending(path: "acpmux"), home: directory,
            socketPath: directory.appending(path: "a.sock").path, daemonArguments: [], childEnvironment: [:])
        let recorder = Recorder()
        let harnesses = SettingsHarnesses(environment: { environment },
            fetch: { _ in [] },
            fetchHealth: { _, _ in Data(#"{"harnesses":[]}"#.utf8) },
            openTerminal: { _ in true },
            accountsCall: { _, method, _ in
                switch method {
                case .accounts, .accountUsage: return Self.accountsReply
                case .accountReadiness:
                    await MainActor.run { recorder.readinessReads += 1 }
                    guard readiness else { throw AcpmuxRPCError(code: -32601, message: "method not found") }
                    return Self.readinessReply
                case .accountSignIn: return Self.start
                case .accountSignInFinish: return Data(#"{"signedIn":true,"account":"codex-login"}"#.utf8)
                default: return Data("{}".utf8)
                }
            },
            claudeStatus: { _, _ in nil },
            userHome: URL(fileURLWithPath: "/Users/alex", isDirectory: true),
            openSignInPage: { url in recorder.opened.append(url); return nil })
        return (harnesses, recorder, OnboardingSignIn.forwarding { harnesses })
    }

    private func page(_ signIn: OnboardingSignIn?) -> (OnboardingModel, OnboardingPageProvider) {
        let model = OnboardingModel(services: MockOnboardingServices(), step: .agents)
        return (model, OnboardingPageProvider(model: model, signIn: signIn))
    }

    private let scripted = PageCallContext(page: "cmux.onboarding")
    private func clicked(_ event: TimeInterval) -> PageCallContext {
        PageCallContext(page: "cmux.onboarding", userGesture: true, gestureEvent: event)
    }

    @Test func theStateCarriesTheRowsAndTheDaemonsReadinessUnchanged() async throws {
        let h = make()
        await h.signIn.refresh()
        let (_, provider) = page(h.signIn)
        let state = try await provider.call("cmux.onboarding.state", params: [:], context: scripted)
        #expect(state["signInReadiness"] == (try JSONValue.parse(Self.readinessReply)))
        #expect(state["signInAccounts"]?.arrayValue?.map { $0["id"]?.stringValue } == ["codex-login", "github:alex"])
    }

    @Test func anOlderDaemonLeavesOnboardingAsBefore() async throws {
        let h = make(readiness: false)
        await h.signIn.refresh()
        let (_, provider) = page(h.signIn)
        let state = try await provider.call("cmux.onboarding.state", params: [:], context: scripted)
        #expect(state["signInAccounts"] == nil && state["signInReadiness"] == nil, "both keys are left out")
        let (_, bare) = page(nil)
        let base = try await bare.call("cmux.onboarding.state", params: [:], context: scripted)
        #expect(state == base)
    }

    @Test func runForwardsAStartOpensItsPageOnceAndKeepsNoCode() async throws {
        let h = make()
        await h.signIn.refresh()
        let (_, provider) = page(h.signIn)
        let reply = try await provider.call("cmux.onboarding.accounts.run",
            params: ["action": "signInStart", "account": "codex-login"], context: clicked(10))
        #expect(reply["signIn"]?["loginId"] == .string("login-9"))
        #expect(h.recorder.opened == [URL(string: "https://auth.openai.com/codex/device")])
        let state = try await provider.call("cmux.onboarding.state", params: [:], context: scripted)
        let text = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        for secret in ["WXYZ-9876", "login-9"] { #expect(!text.contains(secret)) }
    }

    @Test func aStartNeedsItsOwnClickAndTheWaitDoesNot() async throws {
        let h = make()
        let (_, provider) = page(h.signIn)
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.onboarding.accounts.run", params: ["action": "signInStart", "family": "codex"], context: scripted)
        }
        #expect(h.recorder.opened.isEmpty)
        _ = try await provider.call("cmux.onboarding.accounts.run", params: ["action": "signInStart", "family": "codex"], context: clicked(20))
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.onboarding.accounts.run", params: ["action": "accountSwitch", "account": "x"], context: clicked(20))
        }
        // The finish only follows the started sign-in: it runs without a click of its own.
        let before = h.recorder.readinessReads
        let finished = try await provider.call("cmux.onboarding.accounts.run",
            params: ["action": "signInFinish", "loginId": "login-9"], context: scripted)
        #expect(finished["finished"]?["signedIn"] == .bool(true))
        #expect(h.recorder.readinessReads >= before + 1, "a finished sign-in reads both keys again")
    }

    @Test func withoutTheForwarderTheOpIsUnknown() async {
        let (_, provider) = page(nil)
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.onboarding.accounts.run", params: ["action": "signInStart"], context: clicked(1))
        }
    }
}
