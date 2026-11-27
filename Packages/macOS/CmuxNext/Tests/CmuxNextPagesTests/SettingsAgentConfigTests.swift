@testable import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// Settings > Agents > Claude Code & Codex's host: each page call becomes one `cmux --json
/// agent-config settings` run with the key, value and scope as their own arguments, a change or an
/// open runs only on the person's gesture, an open names only a file a fresh `get` lists and that
/// exists, and the lab off answers `{enabled: false}` with nothing run.
@MainActor @Suite struct SettingsAgentConfigTests {
    typealias Runs = SettingsAgentConfigRuns

    static let page = PageCallContext(page: "cmux.settings")
    static let click = PageCallContext(page: "cmux.settings", userGesture: true, gestureEvent: 1)

    func makeProvider(_ runs: Runs, enabled: Bool = true) -> SettingsAgentConfig {
        SettingsAgentConfig(cli: { URL(fileURLWithPath: "/bin/cmux") },
                            enabled: { enabled },
                            runCLI: { _, arguments, _ in
                                runs.arguments.append(arguments)
                                return runs.answer
                            },
                            openFile: { url in runs.opened.append(url.path) },
                            exists: { path in runs.existing.contains(path) })
    }

    @Test func getReadsWithoutAGesture() async throws {
        let runs = Runs()
        let answer = try await makeProvider(runs).call(SettingsAgentConfig.op, params: ["verb": "get", "agent": "codex"], context: Self.page)
        #expect(runs.arguments == [["--json", "agent-config", "settings", "get", "--agent", "codex"]])
        #expect(answer["agent"]?.stringValue == "claude")
    }

    @Test func eachChangeIsOneCLIVerbWithItsWordsAsTheirOwnArguments() async throws {
        let runs = Runs()
        let provider = makeProvider(runs)
        for params: JSONValue in [
            ["verb": "set", "agent": "claude", "key": "model", "value": "opus", "scope": "project"],
            ["verb": "set", "agent": "codex", "key": "model", "value": "-not-a-flag"],
            ["verb": "unset", "agent": "codex", "key": "model_reasoning_effort", "scope": "profile:fast"],
        ] {
            _ = try await provider.call(SettingsAgentConfig.op, params: params, context: Self.click)
        }
        #expect(runs.arguments == [
            ["--json", "agent-config", "settings", "set", "--agent", "claude", "--key", "model", "--value", "opus", "--scope", "project"],
            ["--json", "agent-config", "settings", "set", "--agent", "codex", "--key", "model", "--value", "-not-a-flag"],
            ["--json", "agent-config", "settings", "unset", "--agent", "codex", "--key", "model_reasoning_effort", "--scope", "profile:fast"],
        ])
    }

    @Test func aChangeOrAnOpenWithoutThePersonsGestureIsRefusedAndNothingRuns() async throws {
        let runs = Runs()
        let provider = makeProvider(runs)
        for params: JSONValue in [
            ["verb": "set", "agent": "claude", "key": "model", "value": "opus"],
            ["verb": "unset", "agent": "claude", "key": "model"],
            ["verb": "open", "agent": "claude", "path": "/Users/you/.claude/settings.json"],
        ] {
            await #expect(throws: PageError.self) {
                try await provider.call(SettingsAgentConfig.op, params: params, context: Self.page)
            }
        }
        #expect(runs.arguments.isEmpty)
        #expect(runs.opened.isEmpty)
    }

    @Test func aFlagAnAgentOrAScopeTheCLIWouldMisreadIsRefused() async throws {
        let runs = Runs()
        let provider = makeProvider(runs)
        for params: JSONValue in [
            ["verb": "get", "agent": "--agent"],
            ["verb": "get", "agent": "gemini"],
            ["verb": "set", "agent": "claude", "key": "--scope", "value": "x"],
            ["verb": "set", "agent": "claude", "key": "model"],
            ["verb": "set", "agent": "claude", "key": "model", "value": "x", "scope": "--managed"],
            ["verb": "set", "agent": "claude", "key": "model", "value": "x", "scope": "managed"],
            ["verb": "unset", "agent": "codex", "key": "model", "scope": "profile:-x"],
            ["verb": "remove", "agent": "claude", "key": "model"],
        ] {
            await #expect(throws: PageError.self) {
                try await provider.call(SettingsAgentConfig.op, params: params, context: Self.click)
            }
        }
        #expect(runs.arguments.isEmpty)
    }

    @Test func openOpensOnlyAListedFileThatExists() async throws {
        let runs = Runs()
        let provider = makeProvider(runs)
        runs.existing = ["/Users/you/.claude/settings.json"]
        let opened = try await provider.call(SettingsAgentConfig.op,
                                             params: ["verb": "open", "agent": "claude", "path": "/Users/you/.claude/settings.json"],
                                             context: Self.click)
        #expect(opened["ok"] == .bool(true))
        #expect(runs.opened == ["/Users/you/.claude/settings.json"])
        // Listed but missing: the page's words, and nothing is created or opened.
        let missing = try await provider.call(SettingsAgentConfig.op,
                                              params: ["verb": "open", "agent": "claude", "path": "/Library/Application Support/ClaudeCode/managed-settings.json"],
                                              context: Self.click)
        #expect(missing["message"]?.stringValue == "the file does not exist yet")
        // Not listed: refused.
        await #expect(throws: PageError.self) {
            try await provider.call(SettingsAgentConfig.op, params: ["verb": "open", "agent": "claude", "path": "/etc/hosts"],
                                    context: Self.click)
        }
        #expect(runs.opened == ["/Users/you/.claude/settings.json"])
        #expect(runs.arguments.allSatisfy { $0 == ["--json", "agent-config", "settings", "get", "--agent", "claude"] })
    }

    @Test func theLabOffAnswersDisabledAndRunsNothing() async throws {
        let runs = Runs()
        let answer = try await makeProvider(runs, enabled: false).call(SettingsAgentConfig.op,
                                                                   params: ["verb": "set", "agent": "claude", "key": "model", "value": "opus"],
                                                                   context: Self.click)
        #expect(answer == .object(["enabled": .bool(false)]))
        #expect(runs.arguments.isEmpty)
    }

    @Test func aRefusalIsTheCLIsEnvelope() async throws {
        let runs = Runs()
        runs.answer = (1, Data(), Data(#"{"code":"agent_config.read_only","message":"managed settings are read-only"}"#.utf8))
        let answer = try await makeProvider(runs).call(SettingsAgentConfig.op,
                                                   params: ["verb": "set", "agent": "claude", "key": "model", "value": "opus"],
                                                   context: Self.click)
        #expect(answer["code"]?.stringValue == "agent_config.read_only")
        #expect(answer["message"]?.stringValue == "managed settings are read-only")
    }
}

/// What the fake CLI saw and answers. `nonisolated` against the target's MainActor default: the runner
/// closure is `@Sendable` and runs off the main actor. Each test runs its calls one at a time.
nonisolated final class SettingsAgentConfigRuns: @unchecked Sendable {
    var arguments: [[String]] = []
    var opened: [String] = []
    var existing: Set<String> = []
    var answer: (Int32, Data, Data) = (0, Data(#"""
    {"agent":"claude","files":[
      {"scope":"managed","label":"Managed","path":"/Library/Application Support/ClaudeCode/managed-settings.json","exists":false,"writable":false,"keys":0,"error":null},
      {"scope":"user","label":"User","path":"/Users/you/.claude/settings.json","exists":true,"writable":true,"keys":3,"error":null}
    ],"entries":[],"curated":[],"profiles":[],"notes":[],"keysOnDisk":3,"keysShown":3}
    """#.utf8), Data())
}
