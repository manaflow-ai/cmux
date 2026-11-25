@testable import CmuxNextAgentIntegrations
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// Settings > Automations: the overview is `cmux autocloud overview --json`; create, update, toggle
/// and remove run only on a click, take only listed ids and the revision the overview read, and
/// send the spec on stdin; preview and runs need no click; the secret is never kept in the state.
@MainActor struct SettingsAutomationsCloudTests {
    nonisolated static let cli = URL(fileURLWithPath: "/Applications/cmux NEXT.app/Contents/Resources/bin/cmux")
    nonisolated static let overview = #"""
    {"ok":true,"available":true,"automations":[{"id":"auto_1","name":"Fix CI","enabled":true,"revision":3}],"templates":[]}
    """#
    nonisolated static let click = PageCallContext(page: "cmux.settings", userGesture: true, gestureEvent: 1)
    nonisolated static let script = PageCallContext(page: "cmux.settings")

    nonisolated final class Recorder: @unchecked Sendable {
        var calls: [[String]] = []
        var stdins: [String] = []
        var reply = #"{"ok":true,"automation":{"id":"auto_2"},"secret":"whsec_once"}"#
    }

    static func model(_ recorder: Recorder) -> SettingsAutomationsCloud {
        SettingsAutomationsCloud(cli: { SettingsAutomationsCloudTests.cli }, runCLI: { _, arguments, stdin in
            recorder.calls.append(arguments)
            recorder.stdins.append(stdin.flatMap { String(data: $0, encoding: .utf8) } ?? "")
            if arguments.contains("overview") { return (0, Data(SettingsAutomationsCloudTests.overview.utf8), Data()) }
            return (0, Data(recorder.reply.utf8), Data())
        })
    }

    @Test func refreshReadsTheOverview() async throws {
        let recorder = Recorder()
        let model = Self.model(recorder)
        _ = try await model.run(["action": "refresh"], context: Self.script)
        #expect(recorder.calls == [["autocloud", "overview", "--json"]])
        #expect(model.state["overview"]?["automations"]?.arrayValue?.first?["id"]?.stringValue == "auto_1")
        #expect(model.state["problem"] == .null)
    }

    @Test func editsNeedAClick() async throws {
        let recorder = Recorder()
        let model = Self.model(recorder)
        _ = try await model.run(["action": "refresh"], context: Self.script)
        for params: JSONValue in [
            ["action": "create", "spec": ["name": "x"]],
            ["action": "toggle", "id": "auto_1", "enabled": false],
            ["action": "remove", "id": "auto_1"],
        ] {
            await #expect(throws: PageError.self) { _ = try await model.run(params, context: Self.script) }
        }
        #expect(recorder.calls.count == 1)
    }

    @Test func createSendsTheSpecOnStdinAndKeepsNoSecret() async throws {
        let recorder = Recorder()
        let model = Self.model(recorder)
        let answer = try await model.run(["action": "create", "spec": ["name": "Deploys", "trigger": ["type": "webhook"]]], context: Self.click)
        #expect(recorder.calls.first == ["autocloud", "create", "--json"])
        #expect(recorder.stdins.first?.contains("\"Deploys\"") == true)
        #expect(answer["secret"]?.stringValue == "whsec_once")
        #expect(!model.state.compactText.contains("whsec_once"))
    }

    @Test func updateAndToggleUseTheRevisionTheOverviewRead() async throws {
        let recorder = Recorder()
        let model = Self.model(recorder)
        _ = try await model.run(["action": "refresh"], context: Self.script)
        recorder.reply = #"{"ok":true,"automation":{"id":"auto_1"}}"#
        _ = try await model.run(["action": "update", "id": "auto_1", "spec": ["name": "Fix CI", "revision": 99]], context: Self.click)
        #expect(recorder.calls[1] == ["autocloud", "update", "auto_1", "--json"])
        #expect(recorder.stdins[1].contains("\"revision\":3"))
        _ = try await model.run(["action": "toggle", "id": "auto_1", "enabled": false], context: Self.click)
        #expect(recorder.calls.contains(["autocloud", "disable", "auto_1", "--revision=3", "--json"]))
    }

    @Test func unlistedIdsAndFlagsAreRefused() async throws {
        let recorder = Recorder()
        let model = Self.model(recorder)
        _ = try await model.run(["action": "refresh"], context: Self.script)
        await #expect(throws: PageError.self) { _ = try await model.run(["action": "remove", "id": "--platform=https://x"], context: Self.click) }
        await #expect(throws: PageError.self) { _ = try await model.run(["action": "runs", "id": "auto_9"], context: Self.script) }
        await #expect(throws: PageError.self) { _ = try await model.run(["action": "launch"], context: Self.click) }
        #expect(recorder.calls.count == 1)
    }

    @Test func previewAndRunsNeedNoClick() async throws {
        let recorder = Recorder()
        let model = Self.model(recorder)
        _ = try await model.run(["action": "refresh"], context: Self.script)
        recorder.reply = #"{"ok":true,"prompt":"p","matches":true}"#
        let preview = try await model.run(["action": "preview", "spec": ["name": "x"], "sample": "ci_failure"], context: Self.script)
        #expect(preview["matches"]?.boolValue == true)
        #expect(recorder.calls[1] == ["autocloud", "preview", "--json"])
        #expect(recorder.stdins[1].contains("\"sample\":\"ci_failure\""))
        _ = try await model.run(["action": "runs", "id": "auto_1"], context: Self.script)
        #expect(recorder.calls[2] == ["autocloud", "runs", "auto_1", "--limit=50", "--json"])
    }
}
