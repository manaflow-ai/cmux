@testable import CmuxNextAccounts
@testable import CmuxNextAgentPane
import CmuxNextSettings
import Foundation
import os
import Testing

/// Settings > Agents > Harnesses: each signed-in Claude login's plan comes from `claude auth status`
/// in its own folder, run by the app with the `claude` acpmux's health check found.
@MainActor struct SettingsHarnessesClaudePlanTests {
    struct Asked: Sendable, Equatable {
        let program: String
        let home: String?
    }

    private nonisolated static let accountsReply = Data("""
    {"accounts":[
      {"id":"claude-2","family":"claude","name":"Claude 2","home":"/Users/alex/.cmux/accounts/claude-2",
       "shadowOf":null,"signedIn":true,"plan":null,"email":null,"enabled":true,"builtin":false},
      {"id":"claude-3","family":"claude","name":"Claude 3","home":"/Users/alex/.cmux/accounts/claude-3",
       "shadowOf":null,"signedIn":false,"plan":null,"email":null,"enabled":true,"builtin":false},
      {"id":"claude-login","family":"claude","name":"Claude Code login","home":null,"shadowOf":null,
       "signedIn":true,"plan":null,"email":"alex@example.com","enabled":true,"builtin":true}
    ]}
    """.utf8)

    private func make(path: String? = "/opt/homebrew/bin/claude")
        async -> (harnesses: SettingsHarnesses, asked: OSAllocatedUnfairLock<[Asked]>) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cn-claude-plan-\(UUID().uuidString)")
        let environment = AcpmuxEnvironment(executable: directory.appending(path: "acpmux"), home: directory,
            socketPath: directory.appending(path: "a.sock").path, daemonArguments: [], childEnvironment: [:])
        let asked = OSAllocatedUnfairLock<[Asked]>(initialState: [])
        let health = path.map { #"{"harnesses":[{"id":"claude","path":"\#($0)"}]}"# } ?? #"{"harnesses":[{"id":"claude"}]}"#
        let harnesses = SettingsHarnesses(environment: { environment },
            fetch: { _ in [.init(id: "claude", kind: "claude-stdio", source: "path")] },
            fetchHealth: { _, _ in Data(health.utf8) },
            openTerminal: { _ in },
            accountsCall: { _, method, _ in method == .accounts ? Self.accountsReply : Data("{}".utf8) },
            claudeStatus: { program, home in
                asked.withLock { $0.append(Asked(program: program, home: home)) }
                let plan = home == nil ? "max" : "pro"
                return Data(#"{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"\#(plan)"}"#.utf8)
            },
            userHome: URL(fileURLWithPath: "/Users/alex", isDirectory: true))
        await harnesses.refresh()
        return (harnesses, asked)
    }

    @Test func eachSignedInClaudeLoginGetsItsPlanFromItsOwnFolder() async throws {
        let h = await make()
        let accounts = try #require(h.harnesses.state["accounts"]?.arrayValue)
        let plans = Dictionary(uniqueKeysWithValues: accounts.map { ($0["id"]?.stringValue ?? "", $0["plan"]) })
        #expect(plans["claude-2"] == .string("pro"))
        #expect(plans["claude-login"] == .string("max"))
        #expect(plans["claude-3"] == .null, "a signed-out login is not asked")
        let asked = h.asked.withLock { $0 }.sorted { ($0.home ?? "") < ($1.home ?? "") }
        #expect(asked == [Asked(program: "/opt/homebrew/bin/claude", home: nil),
                          Asked(program: "/opt/homebrew/bin/claude", home: "/Users/alex/.cmux/accounts/claude-2")])
    }

    @Test func noClaudeFoundAsksNothing() async throws {
        let h = await make(path: nil)
        #expect(h.asked.withLock { $0 }.isEmpty)
        let accounts = try #require(h.harnesses.state["accounts"]?.arrayValue)
        #expect(accounts.allSatisfy { $0["plan"] == .null })
    }

    @Test func onlyASignedInClaudeAiLoginNamesAPlan() {
        #expect(ClaudeAuthStatus.plan(Data(#"{"loggedIn":true,"subscriptionType":"team"}"#.utf8)) == "team")
        #expect(ClaudeAuthStatus.plan(Data(#"{"loggedIn":false,"subscriptionType":"pro"}"#.utf8)) == nil)
        #expect(ClaudeAuthStatus.plan(Data(#"{"loggedIn":true,"authMethod":"api_key"}"#.utf8)) == nil)
        #expect(ClaudeAuthStatus.plan(Data(#"{"loggedIn":true,"subscriptionType":null}"#.utf8)) == nil)
        #expect(ClaudeAuthStatus.plan(Data("not json".utf8)) == nil)
    }
}
