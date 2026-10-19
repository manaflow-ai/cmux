@testable import CmuxNextApp
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// Settings > Agents > Agent integrations: the rows come from `cmux --json agent hook status`, a
/// gesture runs `agent hook install|uninstall <id>` and reads status again, and nothing runs
/// before the person clicks. A conflict (a file cmux did not create in the way) offers no Install.
@MainActor struct SettingsAgentIntegrationsTests {
    nonisolated static let cli = URL(fileURLWithPath: "/Applications/cmux NEXT.app/Contents/Resources/bin/cmux")

    nonisolated static let status = #"""
    {"action":"status","helper":"/h/.local/share/cmux-tui/bin/cmux-tui-hook","providers":[
      {"provider":"claude","path":"/h/.claude/settings.json","state":"installed","changed":false},
      {"provider":"codex","path":"/h/.codex/hooks.json","state":"partial","changed":false},
      {"provider":"amp","path":"/h/.config/amp/plugins/cmux-tui-journal.ts","state":"conflict","reason":"not_owned","detail":"/h/.config/amp/plugins/cmux-tui-journal.ts exists and is not owned by cmux-tui","changed":false},
      {"provider":"pi","path":"/h/.pi/agent/extensions/cmux-tui-journal.ts","state":"unavailable","reason":"unreadable","detail":"cannot read","changed":false},
      {"provider":"gemini","path":"/h/.gemini/settings.json","state":"absent","changed":false}
    ],"skipped":[],"errors":[],"activation":"restart agents"}
    """#

    /// A fake CLI: answers `status` with `status`, records every argv.
    nonisolated final class Recorder: @unchecked Sendable {
        var calls: [[String]] = []
        var reply: (Int32, Data, Data) = (0, Data(SettingsAgentIntegrationsTests.status.utf8), Data())
    }

    static func model(_ recorder: Recorder, cli: URL? = SettingsAgentIntegrationsTests.cli) -> SettingsAgentIntegrations {
        SettingsAgentIntegrations(cli: { cli }, runCLI: { _, arguments in
            recorder.calls.append(arguments)
            if arguments.contains("status") { return (0, Data(SettingsAgentIntegrationsTests.status.utf8), Data()) }
            return recorder.reply
        })
    }

    @Test func readsEachProvidersStateAndNeverRunsBeforeAsked() async throws {
        let recorder = Recorder()
        let model = Self.model(recorder)
        #expect(recorder.calls.isEmpty)
        #expect(model.state["providers"]?.arrayValue?.isEmpty == true)
        _ = try await model.run(["action": "refresh"])
        #expect(recorder.calls == [["--json", "agent", "hook", "status"]])
        let rows = try #require(model.state["providers"]?.arrayValue)
        #expect(rows.map { $0["id"]?.stringValue } == ["claude", "codex", "amp", "pi", "gemini"])
        #expect(rows.map { $0["state"]?.stringValue } == ["installed", "partial", "conflict", "unavailable", "absent"])
        #expect(rows[2]["reason"]?.stringValue == "not_owned")
        #expect(rows[2]["path"]?.stringValue == "/h/.config/amp/plugins/cmux-tui-journal.ts")
        #expect(rows[2]["detail"]?.stringValue?.contains("not owned") == true)
        #expect(model.state["problem"] == .null)
    }

    @Test func installRepairAndRemoveRunTheCLIForThatProviderThenReadAgain() async throws {
        let recorder = Recorder()
        let model = Self.model(recorder)
        _ = try await model.run(["action": "refresh"])
        recorder.calls = []
        _ = try await model.run(["action": "install", "id": "gemini"])
        _ = try await model.run(["action": "repair", "id": "codex"])
        _ = try await model.run(["action": "remove", "id": "claude"])
        #expect(recorder.calls == [
            ["--json", "agent", "hook", "install", "gemini"], ["--json", "agent", "hook", "status"],
            ["--json", "agent", "hook", "install", "codex"], ["--json", "agent", "hook", "status"],
            ["--json", "agent", "hook", "uninstall", "claude"], ["--json", "agent", "hook", "status"],
        ])
    }

    @Test func refusesAnInstallOverAConflictOrAnUnlistedProvider() async throws {
        let recorder = Recorder()
        let model = Self.model(recorder)
        _ = try await model.run(["action": "refresh"])
        recorder.calls = []
        await #expect(throws: PageError.self) { try await model.run(["action": "install", "id": "amp"]) }
        await #expect(throws: PageError.self) { try await model.run(["action": "install", "id": "--all"]) }
        await #expect(throws: PageError.self) { try await model.run(["action": "launch", "id": "claude"]) }
        #expect(recorder.calls.isEmpty)
    }

    @Test func aRefusedInstallShowsTheCLIsReasonOnItsRow() async throws {
        let recorder = Recorder()
        recorder.reply = (1, Data(), Data(#"""
        {"code":"local.agent_hooks","message":"one or more coding-agent hook operations failed","details":{"action":"install","providers":[],"errors":["gemini: /h/.gemini/settings.json is not valid JSON"]},"retryable":false}
        """#.utf8))
        let model = Self.model(recorder)
        _ = try await model.run(["action": "refresh"])
        _ = try await model.run(["action": "install", "id": "gemini"])
        let row = try #require(model.state["providers"]?.arrayValue?.first { $0["id"]?.stringValue == "gemini" })
        #expect(row["error"]?.stringValue == "/h/.gemini/settings.json is not valid JSON")
    }

    @Test func withoutTheBundledCLITheCardSaysSoAndRunsNothing() async throws {
        let recorder = Recorder()
        let model = Self.model(recorder, cli: nil)
        _ = try await model.run(["action": "refresh"])
        #expect(model.state["problem"]?.stringValue == "unavailable")
        #expect(recorder.calls.isEmpty)
        #expect(model.state["command"]?.stringValue == "cmux agent hook install")
    }
}
