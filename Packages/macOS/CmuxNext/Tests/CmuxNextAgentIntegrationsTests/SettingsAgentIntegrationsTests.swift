@testable import CmuxNextAgentIntegrations
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

    /// A call backed by the person's click in the page (the host's record).
    nonisolated static let click = PageCallContext(page: "cmux.settings", userGesture: true, gestureEvent: 1)
    /// A call a page script made on its own.
    nonisolated static let script = PageCallContext(page: "cmux.settings")

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
        _ = try await model.run(["action": "refresh"], context: Self.script)
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
        _ = try await model.run(["action": "refresh"], context: Self.script)
        recorder.calls = []
        _ = try await model.run(["action": "install", "id": "gemini"], context: Self.click)
        _ = try await model.run(["action": "repair", "id": "codex"], context: Self.click)
        _ = try await model.run(["action": "remove", "id": "claude"], context: Self.click)
        #expect(recorder.calls == [
            ["--json", "agent", "hook", "install", "gemini"], ["--json", "agent", "hook", "status"],
            ["--json", "agent", "hook", "install", "codex"], ["--json", "agent", "hook", "status"],
            ["--json", "agent", "hook", "uninstall", "claude"], ["--json", "agent", "hook", "status"],
        ])
    }

    @Test func refusesAnInstallOverAConflictOrAnUnlistedProvider() async throws {
        let recorder = Recorder()
        let model = Self.model(recorder)
        _ = try await model.run(["action": "refresh"], context: Self.script)
        recorder.calls = []
        await #expect(throws: PageError.self) { try await model.run(["action": "install", "id": "amp"], context: Self.click) }
        await #expect(throws: PageError.self) { try await model.run(["action": "install", "id": "--all"], context: Self.click) }
        await #expect(throws: PageError.self) { try await model.run(["action": "launch", "id": "claude"], context: Self.click) }
        #expect(recorder.calls.isEmpty)
    }

    @Test func aRefusedInstallShowsTheCLIsReasonOnItsRow() async throws {
        let recorder = Recorder()
        recorder.reply = (1, Data(), Data(#"""
        {"code":"local.agent_hooks","message":"one or more coding-agent hook operations failed","details":{"action":"install","providers":[],"errors":["gemini: /h/.gemini/settings.json is not valid JSON"]},"retryable":false}
        """#.utf8))
        let model = Self.model(recorder)
        _ = try await model.run(["action": "refresh"], context: Self.script)
        _ = try await model.run(["action": "install", "id": "gemini"], context: Self.click)
        let row = try #require(model.state["providers"]?.arrayValue?.first { $0["id"]?.stringValue == "gemini" })
        #expect(row["error"]?.stringValue == "/h/.gemini/settings.json is not valid JSON")
    }

    @Test func withoutTheBundledCLITheCardSaysSoAndRunsNothing() async throws {
        let recorder = Recorder()
        let model = Self.model(recorder, cli: nil)
        _ = try await model.run(["action": "refresh"], context: Self.script)
        #expect(model.state["problem"]?.stringValue == "unavailable")
        #expect(recorder.calls.isEmpty)
        #expect(model.state["command"]?.stringValue == "cmux agent hook install")
    }

    @Test func aPageScriptAloneInstallsAndRemovesNothing() async throws {
        let recorder = Recorder()
        let model = Self.model(recorder)
        _ = try await model.run(["action": "refresh"], context: Self.script)
        recorder.calls = []
        for (action, id) in [("install", "gemini"), ("repair", "codex"), ("remove", "claude")] {
            do {
                _ = try await model.run(["action": .string(action), "id": .string(id)], context: Self.script)
                Issue.record("\(action) ran without a click")
            } catch let error as PageError {
                #expect(error.code == PageNativeOp.userOnlyCode)
            }
        }
        #expect(recorder.calls.isEmpty)
        // A call the person approved on a native sheet is theirs too.
        _ = try await model.run(["action": "install", "id": "gemini"],
                                context: PageCallContext(page: "cmux.settings", origin: "user", confirmed: true))
        #expect(recorder.calls.first == ["--json", "agent", "hook", "install", "gemini"])
    }

    @Test func aCLIThatGivesNoReasonLeavesAKindForThePageToTranslate() async throws {
        let recorder = Recorder()
        recorder.reply = (1, Data(), Data())
        let model = Self.model(recorder)
        _ = try await model.run(["action": "refresh"], context: Self.script)
        _ = try await model.run(["action": "install", "id": "gemini"], context: Self.click)
        let row = try #require(model.state["providers"]?.arrayValue?.first { $0["id"]?.stringValue == "gemini" })
        #expect(row["error"] == .null)
        #expect(row["errorKind"]?.stringValue == "notFinished")
    }
}
