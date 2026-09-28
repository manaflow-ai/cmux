import Foundation
import Testing
@testable import CmuxTerminalCore

@Suite("Agent key hint chord resolver")
struct AgentKeyHintChordResolverTests {
    private func hint(_ line: String, _ agent: AgentKeyHintDetector.Agent = .claudeCode) throws -> AgentKeyHint {
        try #require(AgentKeyHintDetector.hints(in: line, agent: agent).first)
    }

    private func bindings(_ json: String) -> ClaudeCodeKeybindings {
        ClaudeCodeKeybindings(data: Data(json.utf8))
    }

    @Test func sendsThePrintedChordWithoutUserBindings() throws {
        let expand = try hint("(ctrl+o to expand)")
        #expect(AgentKeyHintChordResolver.keys(for: expand, agent: .claudeCode, claudeKeybindings: .empty) == ["ctrl+o"])
    }

    @Test func sendsTheUsersChordForARemappedClaudeAction() throws {
        let user = bindings("""
        {"bindings": [{"context": "Global", "bindings": {"ctrl+o": null, "ctrl+t": "app:toggleTranscript"}}]}
        """)
        #expect(AgentKeyHintChordResolver.keys(for: try hint("(ctrl+o to expand)"), agent: .claudeCode, claudeKeybindings: user) == ["ctrl+t"])

        let cycle = bindings("""
        {"bindings": [{"context": "Chat", "bindings": {"meta+m": "chat:cycleMode"}}]}
        """)
        #expect(AgentKeyHintChordResolver.keys(for: try hint("(shift+tab to cycle)"), agent: .claudeCode, claudeKeybindings: cycle) == ["alt+m"])

        let background = bindings("""
        {"bindings": [{"context": "Task", "bindings": {"ctrl+g": "task:background"}}]}
        """)
        #expect(AgentKeyHintChordResolver.keys(
            for: try hint("ctrl+b ctrl+b to run in background"), agent: .claudeCode, claudeKeybindings: background
        ) == ["ctrl+g", "ctrl+g"])
    }

    @Test func keepsThePrintedChordWhenItIsStillBound() throws {
        let user = bindings("""
        {"bindings": [{"context": "Global", "bindings": {"ctrl+o": "app:toggleTranscript", "ctrl+t": "app:toggleTranscript"}}]}
        """)
        #expect(AgentKeyHintChordResolver.keys(for: try hint("(ctrl+o to expand)"), agent: .claudeCode, claudeKeybindings: user) == ["ctrl+o"])
    }

    @Test func aNonDefaultPrintedChordIsAlreadyTheUsers() throws {
        let user = bindings("""
        {"bindings": [{"context": "Global", "bindings": {"ctrl+t": "app:toggleTranscript"}}]}
        """)
        #expect(AgentKeyHintChordResolver.keys(for: try hint("(ctrl+y to expand)"), agent: .claudeCode, claudeKeybindings: user) == ["ctrl+y"])
    }

    @Test func neverSendsASignalChordFromTheBindingsFile() throws {
        let user = bindings("""
        {"bindings": [{"context": "Chat", "bindings": {"escape": null, "ctrl+c": "chat:cancel"}}]}
        """)
        #expect(AgentKeyHintChordResolver.keys(for: try hint("esc to interrupt"), agent: .claudeCode, claudeKeybindings: user) == ["escape"])
    }

    @Test func otherAgentsUseThePrintedChord() throws {
        let user = bindings("""
        {"bindings": [{"context": "Global", "bindings": {"ctrl+t": "app:toggleTranscript"}}]}
        """)
        #expect(AgentKeyHintChordResolver.keys(for: try hint("ctrl+o to expand", .codex), agent: .codex, claudeKeybindings: user) == ["ctrl+o"])
    }

    @Test func parsesChordSequencesAndDropsUnsendableChords() {
        let user = bindings("""
        {"bindings": [
          {"context": "Chat", "bindings": {"ctrl+x ctrl+k": "chat:killAgents", "cmd+k": "chat:clear", "ctrl+u": null}},
          {"context": "Chat", "bindings": {"Escape": "chat:cancel"}}
        ]}
        """)
        #expect(user.keysByAction["chat:killAgents"] == [["ctrl+x", "ctrl+k"]])
        #expect(user.keysByAction["chat:clear"] == nil)
        #expect(user.keysByAction["chat:cancel"] == [["escape"]])
        #expect(bindings("not json") == .empty)
    }

    @Test func fileIsRereadOnlyAfterItChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("keybindings.json")
        let file = ClaudeCodeKeybindingsFile(url: url)
        #expect(file.current() == .empty, "A missing file has no bindings")

        try Data(#"{"bindings":[{"context":"Global","bindings":{"ctrl+t":"app:toggleTranscript"}}]}"#.utf8).write(to: url)
        #expect(file.current().keysByAction["app:toggleTranscript"] == [["ctrl+t"]])

        try Data(#"{"bindings":[{"context":"Global","bindings":{"ctrl+y":"app:toggleTranscript"}}]}"#.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        #expect(file.current().keysByAction["app:toggleTranscript"] == [["ctrl+y"]])
    }
}

@Suite("Agent key hint click policy")
struct AgentKeyHintClickPolicyTests {
    @Test func plainClickPressesUnlessTheAgentOwnsTheMouse() {
        #expect(AgentKeyHintClickPolicy.pressesHint(mouseCaptured: false, commandHeld: false, otherModifierHeld: false))
        #expect(!AgentKeyHintClickPolicy.pressesHint(mouseCaptured: true, commandHeld: false, otherModifierHeld: false))
        #expect(AgentKeyHintClickPolicy.pressesHint(mouseCaptured: true, commandHeld: true, otherModifierHeld: false))
        #expect(AgentKeyHintClickPolicy.pressesHint(mouseCaptured: false, commandHeld: true, otherModifierHeld: false))
        #expect(!AgentKeyHintClickPolicy.pressesHint(mouseCaptured: false, commandHeld: false, otherModifierHeld: true))
        #expect(!AgentKeyHintClickPolicy.pressesHint(mouseCaptured: true, commandHeld: true, otherModifierHeld: true))
    }
}

@Suite("Terminal legacy key encoding")
struct TerminalLegacyKeyEncodingTests {
    @Test(arguments: [
        ("ctrl+o", "\u{0f}"), ("ctrl-b", "\u{02}"), ("escape", "\u{1b}"), ("tab", "\t"),
        ("shift+tab", "\u{1b}[Z"), ("enter", "\r"), ("space", " "), ("up", "\u{1b}[A"),
        ("down", "\u{1b}[B"), ("right", "\u{1b}[C"), ("left", "\u{1b}[D"), ("?", "?"),
    ])
    func encodesKnownKeys(key: String, text: String) {
        #expect(TerminalLegacyKeyEncoding.text(forNamedKey: key) == text)
    }

    @Test(arguments: ["alt+x", "ctrl+shift+o", "pageup", "f1", "ctrl+?"])
    func skipsKeysWithoutALegacyEncoding(key: String) {
        #expect(TerminalLegacyKeyEncoding.text(forNamedKey: key) == nil)
    }
}
