@testable import CmuxNextAccounts
@testable import CmuxNextAgentPane
import CmuxNextPages
import CmuxNextSettings
import Foundation
import os
import Testing

/// Settings > Agents > Harnesses account rows: Add account for Claude and Codex (a login folder or an
/// API key), Make Default, Rename, Sign Out and Remove, each as its daemon call or terminal line.
@MainActor struct SettingsHarnessesAccountActionsTests {
    @MainActor final class Terminal {
        var lines: [String] = []
    }

    struct Call: Sendable, Equatable {
        let method: String
        let params: [String: String]
    }

    private nonisolated static let accountsReply = Data("""
    {"accounts":[
      {"id":"codex-login","family":"codex","name":"ChatGPT","home":null,"signedIn":true,"enabled":true,
       "builtin":true,"default":true},
      {"id":"claude-2","family":"claude","name":"Claude 2","home":"/Users/alex/.cmux/accounts/claude-2",
       "signedIn":true,"enabled":true,"builtin":false,"default":false},
      {"id":"claude-key","family":"claude","name":"Work key","home":null,"signedIn":true,"enabled":true,
       "builtin":false,"default":false,"key":true},
      {"id":"claude-login","family":"claude","name":"Claude Code login","home":null,"signedIn":true,
       "enabled":true,"builtin":true,"default":true}
    ]}
    """.utf8)

    private func make() async -> (harnesses: SettingsHarnesses, terminal: Terminal, calls: OSAllocatedUnfairLock<[Call]>) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cn-account-actions-\(UUID().uuidString)")
        let environment = AcpmuxEnvironment(executable: directory.appending(path: "acpmux"), home: directory,
            socketPath: directory.appending(path: "a.sock").path, daemonArguments: [], childEnvironment: [:])
        let terminal = Terminal()
        let calls = OSAllocatedUnfairLock<[Call]>(initialState: [])
        let harnesses = SettingsHarnesses(environment: { environment },
            fetch: { _ in [.init(id: "claude", kind: "claude-stdio", source: "path")] },
            fetchHealth: { _, _ in Data(#"{"harnesses":[]}"#.utf8) },
            openTerminal: { terminal.lines.append($0) },
            accountsCall: { _, method, params in
                let flat = params.compactMapValues { value -> String? in
                    if let text = value as? String { return text }
                    if let flag = value as? Bool { return flag ? "true" : "false" }
                    if let list = value as? [String] { return list.joined(separator: ",") }
                    return nil
                }
                if method != .accounts { calls.withLock { $0.append(Call(method: method.rawValue, params: flat)) } }
                return method == .accounts ? Self.accountsReply : Data("{}".utf8)
            },
            userHome: URL(fileURLWithPath: "/Users/alex", isDirectory: true))
        await harnesses.refresh()
        return (harnesses, terminal, calls)
    }

    private func gesture() -> PageCallContext {
        PageCallContext(page: "cmux.settings", origin: "page", confirmed: false, opid: "op", userGesture: true, gestureEvent: 1)
    }

    @Test func statePassesDefaultAndKey() async throws {
        let h = await make()
        let accounts = try #require(h.harnesses.state["accounts"]?.arrayValue)
        #expect(accounts.map { $0["default"] } == [.bool(true), .bool(false), .bool(false), .bool(true)])
        #expect(accounts[2]["key"] == .bool(true))
    }

    @Test func addingAClaudeLoginMakesItsOwnFolderWithNoShadowThenSignsIn() async throws {
        let h = await make()
        _ = try await h.harnesses.run(["action": "accountAdd", "family": "claude", "way": "new", "name": "Personal"],
                                      context: gesture())
        #expect(h.calls.withLock { $0 } == [Call(method: "_acpmux/route/add", params: [
            "id": "claude-4", "name": "Personal", "kind": "direct-subscription", "families": "claude",
            "accountHome": "/Users/alex/.cmux/accounts/claude-4",
        ])])
        let line = try #require(h.terminal.lines.last)
        #expect(line.hasPrefix("CLAUDE_CONFIG_DIR='/Users/alex/.cmux/accounts/claude-4' "))
        #expect(line.hasSuffix("'harness' 'login' '--' 'claude'"))
    }

    @Test func addingAKeyNeedsItsReferenceAndTypesNoSignIn() async throws {
        let h = await make()
        await #expect(throws: PageError.self) {
            _ = try await h.harnesses.run(["action": "accountAdd", "family": "claude", "way": "key"], context: gesture())
        }
        _ = try await h.harnesses.run(["action": "accountAdd", "family": "claude", "way": "key",
                                       "secret": "keychain:anthropic-work"], context: gesture())
        #expect(h.calls.withLock { $0 } == [Call(method: "_acpmux/route/add", params: [
            "id": "claude-4", "name": "Claude 4", "kind": "direct-api-key", "families": "claude",
            "secret": "keychain:anthropic-work",
        ])])
        #expect(h.terminal.lines.isEmpty)
    }

    @Test func makeDefaultBindsTheFamilyAndTheCliLoginClearsIt() async throws {
        let h = await make()
        _ = try await h.harnesses.run(["action": "accountDefault", "account": "claude-2"], context: gesture())
        _ = try await h.harnesses.run(["action": "accountDefault", "account": "claude-login"], context: gesture())
        #expect(h.calls.withLock { $0 } == [
            Call(method: "_acpmux/route/default.set", params: ["scope": "family:claude", "routeId": "claude-2"]),
            Call(method: "_acpmux/route/default.set", params: ["scope": "family:claude"]),
        ])
    }

    @Test func renameSetsTheNameAndTheClaudeLoginHasNone() async throws {
        let h = await make()
        _ = try await h.harnesses.run(["action": "accountRename", "account": "claude-2", "name": " Work "], context: gesture())
        #expect(h.calls.withLock { $0 } == [Call(method: "_acpmux/account/set", params: ["id": "claude-2", "name": "Work"])])
        await #expect(throws: PageError.self) {
            _ = try await h.harnesses.run(["action": "accountRename", "account": "claude-login", "name": "X"], context: gesture())
        }
    }

    @Test func signOutTypesTheCliLogoutInTheAccountsFolder() async throws {
        let h = await make()
        _ = try await h.harnesses.run(["action": "accountSignOut", "account": "claude-2"], context: gesture())
        #expect(h.terminal.lines.last == "CLAUDE_CONFIG_DIR='/Users/alex/.cmux/accounts/claude-2' claude auth logout")
        _ = try await h.harnesses.run(["action": "accountSignOut", "account": "codex-login"], context: gesture())
        #expect(h.terminal.lines.last == "codex logout")
        await #expect(throws: PageError.self) {
            _ = try await h.harnesses.run(["action": "accountSignOut", "account": "claude-key"], context: gesture())
        }
    }

    @Test func signInTypesTheLoginInTheAccountsFolderAndAKeyHasNone() async throws {
        let h = await make()
        _ = try await h.harnesses.run(["action": "accountSignIn", "account": "claude-2"], context: gesture())
        let line = try #require(h.terminal.lines.last)
        #expect(line.hasPrefix("CLAUDE_CONFIG_DIR='/Users/alex/.cmux/accounts/claude-2' "))
        await #expect(throws: PageError.self) {
            _ = try await h.harnesses.run(["action": "accountSignIn", "account": "claude-key"], context: gesture())
        }
        #expect(h.terminal.lines.count == 1)
    }

    @Test func removeTakesAnAddedAccountOnly() async throws {
        let h = await make()
        _ = try await h.harnesses.run(["action": "accountRemove", "account": "claude-key"], context: gesture())
        #expect(h.calls.withLock { $0 } == [Call(method: "_acpmux/route/remove", params: ["id": "claude-key"])])
        await #expect(throws: PageError.self) {
            _ = try await h.harnesses.run(["action": "accountRemove", "account": "codex-login"], context: gesture())
        }
    }

    @Test(arguments: ["accountSignOut", "accountRename", "accountDefault", "accountRemove"])
    func theNewGesturesNeedThePerson(action: String) async {
        let h = await make()
        let script = PageCallContext(page: "cmux.settings", origin: "page", confirmed: false, opid: "op", userGesture: false, gestureEvent: nil)
        await #expect(throws: PageError.self) {
            _ = try await h.harnesses.run(["action": .string(action), "account": "claude-2", "name": "X"], context: script)
        }
        #expect(h.terminal.lines.isEmpty)
        #expect(h.calls.withLock { $0 }.isEmpty)
    }
}
