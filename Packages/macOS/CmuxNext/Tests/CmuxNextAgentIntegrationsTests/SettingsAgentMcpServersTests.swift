@testable import CmuxNextAgentIntegrations
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// Settings > MCP Servers, Claude Code and Codex (Labs `labs.agentCustomization`): the rows come
/// from the bundled `cmux agent-config mcp list --json --project DIR`; a switch, Remove and Add run
/// `agent-config mcp enable|disable|remove|add` only on the person's click, and only for a listed
/// row (an add takes only the fields the CLI knows). Off, the page gets nothing and no CLI runs.
@MainActor struct SettingsAgentMcpServersTests {
    nonisolated static let cli = URL(fileURLWithPath: "/Applications/cmux NEXT.app/Contents/Resources/bin/cmux")
    nonisolated static let click = PageCallContext(page: "cmux.settings", userGesture: true, gestureEvent: 1)
    nonisolated static let script = PageCallContext(page: "cmux.settings")

    nonisolated static let list = #"""
    {"ok":true,"project":"/Users/me/src","elapsedMs":12.5,"problems":[],"servers":[
      {"agent":"claude","name":"agent-memory","scope":"user","transport":"stdio","command":"/bin/m","args":["mcp"],"url":null,"enabled":true,"env":[],"headers":[],"file":"/Users/me/.claude.json","shadowed":false,"removable":true},
      {"agent":"codex","name":"repo","scope":"user","transport":"stdio","command":"/bin/r","args":[],"url":null,"enabled":false,"env":["T"],"headers":[],"file":"/Users/me/.codex/config.toml","shadowed":false,"removable":true}
    ]}
    """#

    nonisolated final class Recorder: @unchecked Sendable {
        var calls: [[String]] = []
        var editReply: (Int32, Data, Data) = (0, Data(#"{"ok":true}"#.utf8), Data())
    }

    static func model(_ recorder: Recorder, enabled: Bool = true) -> SettingsAgentMcpServers {
        SettingsAgentMcpServers(
            cli: { SettingsAgentMcpServersTests.cli },
            enabled: { enabled },
            project: "/Users/me/src/",
            pickFolder: { nil },
            runCLI: { _, arguments, _ in
                recorder.calls.append(arguments)
                if arguments.starts(with: ["agent-config", "mcp", "list"]) { return (0, Data(SettingsAgentMcpServersTests.list.utf8), Data()) }
                return recorder.editReply
            })
    }

    @Test func offShowsNothingAndRunsNothing() async throws {
        let recorder = Recorder()
        let model = Self.model(recorder, enabled: false)
        #expect(model.state["enabled"]?.boolValue == false)
        #expect(model.state["servers"]?.arrayValue?.isEmpty == true)
        await #expect(throws: PageError.self) { try await model.run(["action": "refresh"], context: Self.click) }
        #expect(recorder.calls.isEmpty)
    }

    @Test func refreshListsBothAgentsForTheFolder() async throws {
        let recorder = Recorder()
        let model = Self.model(recorder)
        _ = try await model.run(["action": "refresh"], context: Self.script)
        #expect(recorder.calls == [["agent-config", "mcp", "list", "--project", "/Users/me/src", "--json"]])
        #expect(model.state["servers"]?.arrayValue?.count == 2)
        #expect(model.state["project"]?.stringValue == "/Users/me/src")
        #expect(model.state["cliMs"]?.doubleValue == 12.5)
        #expect(model.state["listMs"]?.doubleValue != nil)
    }

    @Test func editsNeedAClickAndAListedRow() async throws {
        let recorder = Recorder()
        let model = Self.model(recorder)
        _ = try await model.run(["action": "refresh"], context: Self.script)
        let toggle: JSONValue = ["action": "disable", "agent": "claude", "name": "agent-memory", "scope": "user"]
        await #expect(throws: PageError.self) { try await model.run(toggle, context: Self.script) }
        await #expect(throws: PageError.self) {
            try await model.run(["action": "remove", "agent": "claude", "name": "nope", "scope": "user"], context: Self.click)
        }
        await #expect(throws: PageError.self) {
            try await model.run(["action": "remove", "agent": "claude", "name": "--help", "scope": "user"], context: Self.click)
        }
        _ = try await model.run(toggle, context: Self.click)
        #expect(recorder.calls.dropFirst().first == ["agent-config", "mcp", "disable", "agent-memory", "--agent", "claude", "--scope", "user",
                                                     "--project", "/Users/me/src", "--json"])
        // Every edit reads the list again.
        #expect(recorder.calls.last?.starts(with: ["agent-config", "mcp", "list"]) == true)
    }

    @Test func addPassesOnlyTheFieldsTheCLIKnows() async throws {
        let recorder = Recorder()
        let model = Self.model(recorder)
        _ = try await model.run(["action": "add", "agent": "codex", "name": "fs", "scope": "user", "command": "npx",
                                 "args": ["-y", "@acme/fs"], "env": ["TOKEN=abc", "junk"]], context: Self.click)
        // The folder and --json go before `--`, so the server's command keeps only its own words.
        #expect(recorder.calls.first == ["agent-config", "mcp", "add", "fs", "--agent", "codex", "--scope", "user", "--env", "TOKEN=abc",
                                         "--project", "/Users/me/src", "--json", "--", "npx", "-y", "@acme/fs"])
        recorder.calls = []
        _ = try await model.run(["action": "add", "agent": "claude", "name": "docs", "scope": "local", "url": "https://d.example/mcp",
                                 "transport": "sse", "headers": ["X-Key=v"]], context: Self.click)
        #expect(recorder.calls.first == ["agent-config", "mcp", "add", "docs", "--agent", "claude", "--scope", "local", "--url",
                                         "https://d.example/mcp", "--transport", "sse", "--header", "X-Key=v",
                                         "--project", "/Users/me/src", "--json"])
    }

    @Test func aRefusalShowsOnItsRow() async throws {
        let recorder = Recorder()
        recorder.editReply = (1, Data(#"{"ok":false,"why":"Codex has no user server named repo"}"#.utf8), Data())
        let model = Self.model(recorder)
        _ = try await model.run(["action": "refresh"], context: Self.script)
        _ = try await model.run(["action": "remove", "agent": "codex", "name": "repo", "scope": "user"], context: Self.click)
        #expect(model.state["error"]?["key"]?.stringValue == "codex:user:repo")
        #expect(model.state["error"]?["why"]?.stringValue == "Codex has no user server named repo")
    }
}
