@testable import CmuxNextAgentIntegrations
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// Settings > Agents > Claude Code & Codex > Skills: nothing (and no CLI run) while Labs is off;
/// on, the rows are `cmux agent-config skills list --json`; open and reveal take only a listed file;
/// on/off run `skills on|off FILE` only on a click and read the list again.
@MainActor struct SettingsAgentSkillsTests {
    nonisolated static let cli = URL(fileURLWithPath: "/Applications/cmux NEXT.app/Contents/Resources/bin/cmux")
    nonisolated static let file = "/Users/me/.claude/skills/wrangler/SKILL.md"
    nonisolated static let list = #"""
    {"skills":[
      {"agent":"claude","kind":"skill","scope":"user","name":"wrangler","description":"Deploy Workers.","path":"/Users/me/.claude/skills/wrangler/SKILL.md","enabled":true,"switchFile":"/Users/me/.claude/settings.json"},
      {"agent":"codex","kind":"skill","scope":"system","name":"imagegen","description":"Images","path":"/Users/me/.codex/skills/.system/imagegen/SKILL.md","enabled":true,"switchFile":"/Users/me/.codex/config.toml"}
    ],"problems":[],"sources":{"claude":"files","codex":"app-server"},"counts":{},"elapsedMs":8.5}
    """#
    nonisolated static let click = PageCallContext(page: "cmux.settings", userGesture: true, gestureEvent: 1)
    nonisolated static let script = PageCallContext(page: "cmux.settings")

    nonisolated final class Recorder: @unchecked Sendable {
        var calls: [[String]] = []
        var setReply: (Int32, Data, Data) = (0, Data(#"{"skill":{}}"#.utf8), Data())
    }

    static func model(_ recorder: Recorder, enabled: Bool = true, folder: URL? = nil,
                      opened: @escaping @MainActor (URL) -> Void = { _ in },
                      revealed: @escaping @MainActor (URL) -> Void = { _ in }) -> SettingsAgentSkills {
        SettingsAgentSkills(
            cli: { SettingsAgentSkillsTests.cli }, enabled: { enabled }, workingFolder: { folder },
            openFile: opened, reveal: revealed,
            runCLI: { _, arguments, _ in
                recorder.calls.append(arguments)
                if arguments.contains("list") { return (0, Data(SettingsAgentSkillsTests.list.utf8), Data()) }
                return recorder.setReply
            })
    }

    @Test func labsOffShowsNothingAndRunsNothing() async throws {
        let recorder = Recorder()
        let model = Self.model(recorder, enabled: false)
        _ = try await model.run(["action": "refresh"], context: Self.script)
        _ = try await model.run(["action": "off", "path": .string(Self.file)], context: Self.click)
        #expect(model.state == ["enabled": .bool(false)])
        #expect(recorder.calls.isEmpty)
    }

    @Test func listsEachSkillFromTheCLIWithTheFocusedFolder() async throws {
        let recorder = Recorder()
        let model = Self.model(recorder, folder: URL(fileURLWithPath: "/Users/me/repo", isDirectory: true))
        #expect(recorder.calls.isEmpty)
        _ = try await model.run(["action": "refresh"], context: Self.script)
        #expect(recorder.calls == [["agent-config", "skills", "list", "--json", "--cwd", "/Users/me/repo/"]])
        let rows = try #require(model.state["skills"]?.arrayValue)
        #expect(rows.map { $0["name"]?.stringValue } == ["wrangler", "imagegen"])
        #expect(model.state["sources"]?["codex"]?.stringValue == "app-server")
        #expect(model.state["problem"] == .null)
    }

    @Test func openAndRevealTakeOnlyAListedFile() async throws {
        let recorder = Recorder()
        var opened: [URL] = [], revealed: [URL] = []
        let model = Self.model(recorder, opened: { opened.append($0) }, revealed: { revealed.append($0) })
        _ = try await model.run(["action": "refresh"], context: Self.script)
        _ = try await model.run(["action": "open", "path": .string(Self.file)], context: Self.script)
        _ = try await model.run(["action": "reveal", "path": .string(Self.file)], context: Self.script)
        #expect(opened.map(\.path) == [Self.file])
        #expect(revealed.map(\.path) == [Self.file])
        await #expect(throws: PageError.self) {
            _ = try await model.run(["action": "open", "path": "/etc/passwd"], context: Self.click)
        }
    }

    @Test func aSwitchRunsOnlyOnAClickAndReadsAgain() async throws {
        let recorder = Recorder()
        let model = Self.model(recorder)
        _ = try await model.run(["action": "refresh"], context: Self.script)
        await #expect(throws: PageError.self) {
            _ = try await model.run(["action": "off", "path": .string(Self.file), "agent": "claude"], context: Self.script)
        }
        #expect(recorder.calls.count == 1)
        _ = try await model.run(["action": "off", "path": .string(Self.file), "agent": "claude"], context: Self.click)
        #expect(recorder.calls[1] == ["agent-config", "skills", "off", Self.file, "--json", "--agent", "claude"])
        #expect(recorder.calls[2].contains("list"))
        #expect(model.state["refusal"] == .null)
        // A refusal shows on its row in the CLI's words.
        recorder.setReply = (1, Data(), Data(#"{"code":"skill.no_switch","message":"wrangler has no on/off switch"}"#.utf8))
        _ = try await model.run(["action": "on", "path": .string(Self.file)], context: Self.click)
        #expect(model.state["refusal"]?["message"]?.stringValue == "wrangler has no on/off switch")
        #expect(model.state["refusal"]?["path"]?.stringValue == Self.file)
    }

    /// New Command: `commands add NAME --agent A --prompt TEXT` only on a click, then the list again; the saved
    /// command is reported, a refusal shows in the form (`new-command`) in the CLI's words.
    @Test func newCommandSavesOnlyOnAClick() async throws {
        let recorder = Recorder()
        let model = Self.model(recorder)
        let add: JSONValue = ["action": "add", "agent": "cmux", "name": "standup", "prompt": "Write my standup.",
                              "description": "My standup"]
        await #expect(throws: PageError.self) { _ = try await model.run(add, context: Self.script) }
        #expect(recorder.calls.isEmpty)
        recorder.setReply = (0, Data(#"{"command":{"agent":"cmux","name":"standup","invocation":"/standup","description":"My standup","prompt":"Write my standup.","path":"/Users/me/.config/cmux/commands/standup.md"}}"#.utf8), Data())
        _ = try await model.run(add, context: Self.click)
        #expect(recorder.calls[0] == ["agent-config", "commands", "add", "standup", "--agent", "cmux", "--prompt",
                                      "Write my standup.", "--description", "My standup", "--json"])
        #expect(recorder.calls[1].contains("list"))
        #expect(model.state["added"]?["invocation"]?.stringValue == "/standup")
        #expect(model.state["refusal"] == .null)
        recorder.setReply = (1, Data(), Data(#"{"code":"command.exists","message":"standup.md already exists"}"#.utf8))
        _ = try await model.run(add, context: Self.click)
        #expect(model.state["refusal"]?["path"]?.stringValue == "new-command")
        #expect(model.state["refusal"]?["message"]?.stringValue == "standup.md already exists")
        await #expect(throws: PageError.self) {
            _ = try await model.run(["action": "add", "agent": "gemini", "name": "x", "prompt": "y"], context: Self.click)
        }
    }
}
