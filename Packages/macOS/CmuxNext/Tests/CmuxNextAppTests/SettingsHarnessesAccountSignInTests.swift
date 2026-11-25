@testable import CmuxNextAccounts
@testable import CmuxNextAgentPane
import CmuxNextPages
import CmuxNextSettings
import Foundation
import os
import Testing

/// Settings > Accounts' in-place sign-in (logins done right): its six gestures forwarded to acpmux's
/// `_acpmux/account/*`, the sign-in rows in the page state, the page a start opens, and the
/// terminal sign-in an older daemon keeps.
@MainActor struct SettingsHarnessesAccountSignInTests {
    @MainActor final class Recorder {
        var lines: [String] = []
        var opened: [URL] = []
    }

    struct Call: Sendable, Equatable {
        let method: String
        let params: [String: String]
    }

    private nonisolated static let accountsReply = Data("""
    {"accounts":[
      {"id":"codex-login","family":"codex","name":"ChatGPT","home":null,"signedIn":true,"enabled":true,
       "builtin":true,"default":true,"email":"alex@example.com","plan":"plus"},
      {"id":"claude-2","family":"claude","name":"Claude 2","home":"/Users/alex/.cmux/accounts/claude-2",
       "signedIn":true,"enabled":true,"builtin":false,"default":false},
      {"id":"claude-key","family":"claude","name":"Work key","home":null,"signedIn":true,"enabled":true,
       "builtin":false,"default":false,"key":true},
      {"id":"github:alex","family":"github","name":"alex","signedIn":true,"default":true,"builtin":false}
    ]}
    """.utf8)

    private nonisolated static let githubStart = Data("""
    {"account":"github","loginId":"login-1","url":"https://github.com/login/device","userCode":"ABCD-1234",
     "needsCode":false,"expiresAtMs":4102444800000,"added":true}
    """.utf8)

    /// `missing`: the sign-in methods answer method-not-found (an older daemon).
    private func make(missing: Bool = false, reply: Data = githubStart, preloaded: Bool = true)
        async -> (harnesses: SettingsHarnesses, recorder: Recorder, calls: OSAllocatedUnfairLock<[Call]>) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cn-account-sign-in-\(UUID().uuidString)")
        let environment = AcpmuxEnvironment(executable: directory.appending(path: "acpmux"), home: directory,
            socketPath: directory.appending(path: "a.sock").path, daemonArguments: [], childEnvironment: [:])
        let recorder = Recorder()
        let calls = OSAllocatedUnfairLock<[Call]>(initialState: [])
        let harnesses = SettingsHarnesses(environment: { environment },
            fetch: { _ in [] },
            fetchHealth: { _, _ in Data(#"{"harnesses":[]}"#.utf8) },
            openTerminal: { line in
                recorder.lines.append(line)
                return true
            },
            accountsCall: { _, method, params in
                if method == .accounts || method == .accountUsage { return Self.accountsReply }
                if method == .accountReadiness { return Data(#"{"providers":[]}"#.utf8) }
                calls.withLock { $0.append(Call(method: method.rawValue, params: params.compactMapValues { $0 as? String })) }
                if missing, SettingsHarnesses.signInMethods.values.contains(method) {
                    throw AcpmuxRPCError(code: -32601, message: "method not found")
                }
                if method == .accountSignIn { return reply }
                if method == .accountSignInFinish { return Data(#"{"signedIn":true,"account":"github:alex"}"#.utf8) }
                return Data("{}".utf8)
            },
            claudeStatus: { _, _ in nil },
            userHome: URL(fileURLWithPath: "/Users/alex", isDirectory: true),
            openSignInPage: { url in recorder.opened.append(url); return nil })
        if preloaded { await harnesses.readAccounts(environment, generation: harnesses.generation) }
        return (harnesses, recorder, calls)
    }

    @Test func tableMapsAllSixGestures() {
        let table = SettingsHarnesses.signInMethods.mapValues(\.rawValue)
        #expect(table == [
            "signInStart": "_acpmux/account/sign_in",
            "signInFinish": "_acpmux/account/sign_in.finish",
            "signInCancel": "_acpmux/account/sign_in.cancel",
            "accountSwitch": "_acpmux/account/switch",
            "accountRemove": "_acpmux/account/remove",
            "accountSignOut": "_acpmux/account/sign_out",
        ])
    }

    @Test func theFirstSettingsAccountsReadLoadsSignInRows() async {
        let h = await make(preloaded: false)
        #expect(h.harnesses.signInAccountsState == .null)
        await h.harnesses.loadSignInAccounts(ready: { nil })
        #expect(h.harnesses.signInAccountsState == .null)
        await h.harnesses.loadSignInAccounts()
        #expect(h.harnesses.signInAccountsState.arrayValue?.contains { $0["id"]?.stringValue == "claude-2" } == true)
    }

    @Test func stateCarriesTheRowsAndNoSecret() async throws {
        let h = await make()
        let rows = try #require(h.harnesses.signInAccountsState.arrayValue)
        // An API-key route is no sign-in.
        #expect(rows.map { $0["id"]?.stringValue } == ["codex-login", "claude-2", "github:alex"])
        #expect(rows.first?["email"] == .string("alex@example.com"))
        #expect(rows.last?["family"] == .string("github"))
        #expect(rows.last?["default"] == .bool(true))
        _ = try await h.harnesses.runSignIn("signInStart", ["action": "signInStart", "family": "github", "provider": "github"])
        let text = String(decoding: try JSONEncoder().encode(h.harnesses.signInAccountsState), as: UTF8.self)
        for secret in ["ABCD-1234", "login-1", "home", "/Users/alex", "key"] { #expect(!text.contains(secret)) }
    }

    @Test func startOpensItsPageOnceAndAnswersIt() async throws {
        let h = await make()
        let reply = try #require(try await h.harnesses.runSignIn("signInStart",
            ["action": "signInStart", "family": "github", "provider": "github"]))
        #expect(h.recorder.opened == [URL(string: "https://github.com/login/device")])
        #expect(reply["signIn"]?["userCode"] == .string("ABCD-1234"))
        #expect(h.calls.withLock { $0 } == [Call(method: "_acpmux/account/sign_in", params: ["family": "github"])])
        // A listed account is named alone: the daemon refuses an account and a family together.
        _ = try await h.harnesses.runSignIn("signInStart", ["action": "signInStart", "family": "claude", "account": "claude-2"])
        #expect(h.calls.withLock { $0.last } == Call(method: "_acpmux/account/sign_in", params: ["account": "claude-2"]))
        let finished = try await h.harnesses.runSignIn("signInFinish", ["action": "signInFinish", "loginId": "login-1", "code": "x"])
        #expect(finished?["finished"]?["signedIn"] == .bool(true))
        #expect(h.calls.withLock { $0.last } == Call(method: "_acpmux/account/sign_in.finish", params: ["loginId": "login-1", "code": "x"]))
        #expect(h.recorder.opened.count == 2)
    }

    @Test func startOpensClaudesAutomaticPageAndNoOtherHost() async throws {
        let auto = "https://claude.ai/oauth/authorize?code=true&redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fcallback"
        let claude = await make(reply: Data("""
        {"account":"claude-2","loginId":"l","url":"https://claude.com/cai/oauth/authorize?code=true","autoUrl":"\(auto)",
         "callbackPort":54545,"needsCode":true,"expiresAtMs":1,"added":false}
        """.utf8))
        _ = try await claude.harnesses.runSignIn("signInStart", ["action": "signInStart", "account": "claude-2"])
        #expect(claude.recorder.opened == [URL(string: auto)])
        let plain = await make(reply: Data(#"{"account":"x","loginId":"l","url":"http://example.com/login","needsCode":false}"#.utf8))
        _ = try await plain.harnesses.runSignIn("signInStart", ["action": "signInStart", "family": "codex"])
        #expect(plain.recorder.opened.isEmpty)
    }

    @Test func olderDaemonKeepsTheTerminalSignIn() async throws {
        let h = await make(missing: true)
        // A start types the terminal sign-in here, in the same call (the click still counts as the
        // person's), and says so: the page runs no fallback of its own.
        let start = try await h.harnesses.runSignIn("signInStart",
            ["action": "signInStart", "family": "claude", "provider": "claude", "account": "claude-2"])
        #expect(start == ["terminal": true])
        #expect(h.recorder.opened.isEmpty)
        let own = try #require(h.recorder.lines.last)
        #expect(own.hasPrefix("CLAUDE_CONFIG_DIR='/Users/alex/.cmux/accounts/claude-2' "))
        #expect(own.contains("login"))
        // GitHub's start is gh's own browser login.
        let github = try await h.harnesses.runSignIn("signInStart", ["action": "signInStart", "family": "github"])
        #expect(github == ["terminal": true])
        #expect(h.recorder.lines.last == "gh auth login --hostname github.com --git-protocol https --web")
        // A new login: its folder and name, then its sign-in.
        _ = try await h.harnesses.runSignIn("signInStart", ["action": "signInStart", "family": "codex", "name": "Work"])
        #expect(h.calls.withLock { $0 }.contains { $0.method == "_acpmux/route/add" && $0.params["name"] == "Work" })
        _ = try await h.harnesses.runSignIn("accountSignOut", ["action": "accountSignOut", "account": "claude-2"])
        #expect(h.recorder.lines.last == "CLAUDE_CONFIG_DIR='/Users/alex/.cmux/accounts/claude-2' claude auth logout")
        _ = try await h.harnesses.runSignIn("accountSwitch", ["action": "accountSwitch", "account": "claude-2"])
        #expect(h.calls.withLock { $0.last } == Call(method: "_acpmux/route/default.set",
                                                     params: ["scope": "family:claude", "routeId": "claude-2"]))
        #expect(try await h.harnesses.runSignIn("refresh", [:]) == nil)
    }

    @Test func refusalAnswersItsReason() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cn-account-sign-in-\(UUID().uuidString)")
        let environment = AcpmuxEnvironment(executable: directory.appending(path: "acpmux"), home: directory,
            socketPath: directory.appending(path: "a.sock").path, daemonArguments: [], childEnvironment: [:])
        let harnesses = SettingsHarnesses(environment: { environment }, openTerminal: { _ in true },
            accountsCall: { _, _, _ in throw AcpmuxRPCError(code: -32000, name: "not_installed", message: "gh is not installed") })
        let reply = try await harnesses.runSignIn("signInStart", ["action": "signInStart", "family": "github"])
        #expect(reply?["reason"] == .string("not_installed"))
    }
}
