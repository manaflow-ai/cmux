@testable import CmuxNextAccounts
@testable import CmuxNextAgentPane
import CmuxNextPages
import CmuxNextSettings
import Foundation
import os
import Testing
@testable import CmuxNextApp

/// Settings > Agents > Harnesses accounts (`_acpmux/accounts`): the page state, the gestures'
/// daemon calls, the shadow-home add and its sign-in line, with the daemon and terminal faked.
@MainActor struct SettingsHarnessesAccountsTests {
    @MainActor final class Terminal {
        var lines: [String] = []
    }

    struct Call: Sendable {
        let method: String
        let params: [String: String]
    }

    /// Holds each usage read until released, and says when the first one started.
    actor UsageGate {
        private var held = true
        private var started = false
        private var starting: [CheckedContinuation<Void, Never>] = []
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func pass() async {
            started = true
            starting.forEach { $0.resume() }
            starting = []
            guard held else { return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func untilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { starting.append($0) }
        }

        func release() {
            held = false
            waiting.forEach { $0.resume() }
            waiting = []
        }
    }

    private nonisolated static let accountsReply = Data("""
    {"accounts":[
      {"id":"codex-login","family":"codex","name":"ChatGPT","home":null,"shadowOf":null,"signedIn":true,
       "plan":"pro","email":"alex@example.com","enabled":true,"builtin":true},
      {"id":"codex-2","family":"codex","name":"ChatGPT 2","home":"/Users/alex/.cmux/accounts/codex-2",
       "shadowOf":"/Users/alex/.codex","signedIn":false,"plan":null,"email":null,"enabled":false,"builtin":false}
    ]}
    """.utf8)

    private nonisolated static let usageReply = Data("""
    {"id":"codex-login","usageLimits":{"windows":[{"id":"session","usedPercent":22,"windowMins":300},
      {"id":"weekly","usedPercent":41,"windowMins":10080,"resetsAt":1790500000}],"plan":"pro"}}
    """.utf8)

    private func make(missing: Bool = false, usageGate: UsageGate? = nil, refresh: Bool = true) async -> (harnesses: SettingsHarnesses, terminal: Terminal,
                                                       calls: OSAllocatedUnfairLock<[Call]>) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cn-settings-accounts-\(UUID().uuidString)")
        let environment = AcpmuxEnvironment(executable: directory.appending(path: "acpmux"), home: directory,
            socketPath: directory.appending(path: "a.sock").path, daemonArguments: [], childEnvironment: [:])
        let terminal = Terminal()
        let calls = OSAllocatedUnfairLock<[Call]>(initialState: [])
        let harnesses = SettingsHarnesses(environment: { environment },
            fetch: { _ in [.init(id: "codex", kind: "acp", source: "path")] },
            fetchHealth: { _, _ in Data(#"{"harnesses":[{"id":"codex","checkedAt":1700000000000}]}"#.utf8) },
            openTerminal: { terminal.lines.append($0) },
            accountsCall: { _, method, params in
                let flat = params.compactMapValues { value -> String? in
                    if let text = value as? String { return text }
                    if let flag = value as? Bool { return flag ? "true" : "false" }
                    if let list = value as? [String] { return list.joined(separator: ",") }
                    return nil
                }
                calls.withLock { $0.append(Call(method: method.rawValue, params: flat)) }
                if missing { throw AcpmuxRPCError(code: -32601, message: "method not found") }
                switch method {
                case .accounts: return Self.accountsReply
                case .accountUsage:
                    await usageGate?.pass()
                    return Self.usageReply
                default: return Data("{}".utf8)
                }
            },
            userHome: URL(fileURLWithPath: "/Users/alex", isDirectory: true))
        if refresh { await harnesses.refresh() }
        return (harnesses, terminal, calls)
    }

    private func gesture() -> PageCallContext {
        PageCallContext(page: "cmux.settings", origin: "page", confirmed: false, opid: "op", userGesture: true, gestureEvent: 1)
    }

    @Test func statePassesAccountsWithFoldersUnderHomeAndTheCheckTime() async throws {
        let h = await make()
        let accounts = try #require(h.harnesses.state["accounts"]?.arrayValue)
        #expect(accounts.map { $0["id"]?.stringValue } == ["codex-login", "codex-2"])
        #expect(accounts[0]["home"] == .null)
        #expect(accounts[0]["defaultHome"] == .string("~/.codex"))
        #expect(accounts[0]["plan"] == .string("pro"))
        #expect(accounts[0]["email"] == .string("alex@example.com"))
        #expect(accounts[1]["home"] == .string("~/.cmux/accounts/codex-2"))
        #expect(accounts[1]["shadowOf"] == .string("~/.codex"))
        let row = try #require(h.harnesses.state["harnesses"]?.arrayValue?.first)
        #expect(row["checkedAt"] == .number(1_700_000_000_000))
    }

    /// Usage at rest (`_acpmux/account/usage`): asked once per signed-in Codex account when the page
    /// refreshes, and passed under that account; a signed-out one is not asked and shows none.
    @Test func refreshReadsEachSignedInCodexAccountsUsageAndPassesItInItsRow() async throws {
        let h = await make()
        let asked = h.calls.withLock { $0 }.filter { $0.method == "_acpmux/account/usage" }
        #expect(asked.map { $0.params } == [["id": "codex-login"]])
        let accounts = try #require(h.harnesses.state["accounts"]?.arrayValue)
        let usage = try #require(accounts[0]["usage"])
        #expect(usage["plan"] == .string("pro"))
        #expect(usage["windows"]?.arrayValue?.map { $0["id"]?.stringValue } == ["session", "weekly"])
        #expect(usage["windows"]?.arrayValue?.last?["resetsAt"] == .number(1_790_500_000))
        #expect(accounts[1]["usage"] == .null)
        #expect(SettingsHarnesses.usageLimits(Data(#"{"id":"x","usageLimits":null,"skipped":"keychain"}"#.utf8)) == .null)
    }

    /// A refresh while an account's usage read runs starts no second one (the daemon caches only
    /// a finished read), and the running read still shows its answer when it ends.
    @Test func aRefreshDuringAUsageReadStartsNoSecondReadForThatAccount() async throws {
        let gate = UsageGate()
        let h = await make(usageGate: gate, refresh: false)
        let first = Task { await h.harnesses.refresh() }
        await gate.untilStarted()
        await h.harnesses.refresh()
        await gate.release()
        await first.value
        let asked = h.calls.withLock { $0 }.filter { $0.method == "_acpmux/account/usage" }
        #expect(asked.map { $0.params } == [["id": "codex-login"]])
        let accounts = try #require(h.harnesses.state["accounts"]?.arrayValue)
        #expect(accounts[0]["usage"]?["plan"] == .string("pro"))
        #expect(h.harnesses.usageReading.isEmpty)
    }

    @Test func aDaemonWithoutAccountsLeavesThemOut() async {
        let h = await make(missing: true)
        #expect(h.harnesses.state["accounts"] == .null)
    }

    @Test func addMakesACodexShadowHomeThenTypesItsSignIn() async throws {
        let h = await make()
        _ = try await h.harnesses.run(["action": "accountAdd", "family": "codex"], context: gesture())
        let add = try #require(h.calls.withLock { $0 }.first { $0.method == "_acpmux/route/add" })
        #expect(add.params == ["id": "codex-3", "name": "ChatGPT 3", "kind": "direct-subscription", "families": "codex",
                               "accountHome": "/Users/alex/.cmux/accounts/codex-3", "shadow": "true"])
        let line = try #require(h.terminal.lines.last)
        #expect(line.hasPrefix("CODEX_HOME='/Users/alex/.cmux/accounts/codex-3' "))
        #expect(line.hasSuffix("'harness' 'login' '--' 'codex'"))
    }

    @Test func signInUsesTheListedFolderAndTheSwitchSetsEnabled() async throws {
        let h = await make()
        _ = try await h.harnesses.run(["action": "accountSignIn", "account": "codex-2"], context: gesture())
        #expect(h.terminal.lines.last?.hasPrefix("CODEX_HOME='/Users/alex/.cmux/accounts/codex-2' ") == true)
        // The CLI's own login signs in with no folder of its own.
        _ = try await h.harnesses.run(["action": "accountSignIn", "account": "codex-login"], context: gesture())
        #expect(h.terminal.lines.last?.contains("CODEX_HOME") == false)
        _ = try await h.harnesses.run(["action": "accountEnable", "account": "codex-2", "on": true], context: gesture())
        let set = try #require(h.calls.withLock { $0 }.last { $0.method == "_acpmux/account/set" })
        #expect(set.params == ["id": "codex-2", "enabled": "true"])
    }

    @Test(arguments: ["accountEnable", "accountAdd", "accountSignIn"])
    func accountGesturesNeedThePerson(action: String) async {
        let h = await make()
        let script = PageCallContext(page: "cmux.settings", origin: "page", confirmed: false, opid: "op", userGesture: false, gestureEvent: nil)
        await #expect(throws: PageError.self) {
            _ = try await h.harnesses.run(["action": .string(action), "account": "codex-2", "family": "codex", "on": true],
                                          context: script)
        }
        #expect(h.terminal.lines.isEmpty)
        // Only the refresh's reads: the list and the usage of each signed-in Codex account.
        #expect(h.calls.withLock { $0 }.allSatisfy { ["_acpmux/accounts", "_acpmux/account/usage"].contains($0.method) })
    }
}
