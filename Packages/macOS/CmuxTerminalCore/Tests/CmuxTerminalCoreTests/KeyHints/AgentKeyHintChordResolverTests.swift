import Foundation
import Testing
@testable import CmuxTerminalCore

@Suite("Agent key hint chord resolver")
struct AgentKeyHintChordResolverTests {
    private func hint(_ line: String, _ agent: AgentKeyHintDetector.Agent = .claudeCode) throws -> AgentKeyHint {
        try #require(AgentKeyHintDetector(agent: agent).hints(in: line, inLiveRegion: true).first)
    }

    private func bindings(_ json: String) -> ClaudeCodeKeybindings {
        ClaudeCodeKeybindings(data: Data(json.utf8))
    }

    @Test func sendsThePrintedChordWithoutUserBindings() throws {
        let expand = try hint("(ctrl+o to expand)")
        #expect(AgentKeyHintChordResolver(claudeKeybindings: .empty).keys(for: expand, agent: .claudeCode) == ["ctrl+o"])
    }

    @Test func sendsTheUsersChordForARemappedClaudeAction() throws {
        let user = bindings("""
        {"bindings": [{"context": "Global", "bindings": {"ctrl+o": null, "ctrl+t": "app:toggleTranscript"}}]}
        """)
        #expect(AgentKeyHintChordResolver(claudeKeybindings: user).keys(for: try hint("(ctrl+o to expand)"), agent: .claudeCode) == ["ctrl+t"])

        let cycle = bindings("""
        {"bindings": [{"context": "Chat", "bindings": {"meta+m": "chat:cycleMode"}}]}
        """)
        #expect(AgentKeyHintChordResolver(claudeKeybindings: cycle).keys(for: try hint("(shift+tab to cycle)"), agent: .claudeCode) == ["alt+m"])

        let background = bindings("""
        {"bindings": [{"context": "Task", "bindings": {"ctrl+g": "task:background"}}]}
        """)
        #expect(AgentKeyHintChordResolver(claudeKeybindings: background).keys(for: try hint("ctrl+b ctrl+b to run in background"), agent: .claudeCode) == ["ctrl+g", "ctrl+g"])
    }

    @Test func keepsThePrintedChordWhenItIsStillBound() throws {
        let user = bindings("""
        {"bindings": [{"context": "Global", "bindings": {"ctrl+o": "app:toggleTranscript", "ctrl+t": "app:toggleTranscript"}}]}
        """)
        #expect(AgentKeyHintChordResolver(claudeKeybindings: user).keys(for: try hint("(ctrl+o to expand)"), agent: .claudeCode) == ["ctrl+o"])
    }

    @Test func aNonDefaultPrintedChordIsAlreadyTheUsers() throws {
        let user = bindings("""
        {"bindings": [{"context": "Global", "bindings": {"ctrl+t": "app:toggleTranscript"}}]}
        """)
        #expect(AgentKeyHintChordResolver(claudeKeybindings: user).keys(for: try hint("(ctrl+y to expand)"), agent: .claudeCode) == ["ctrl+y"])
    }

    @Test func neverSendsASignalChordFromTheBindingsFile() throws {
        let user = bindings("""
        {"bindings": [{"context": "Chat", "bindings": {"escape": null, "ctrl+c": "chat:cancel"}}]}
        """)
        #expect(AgentKeyHintChordResolver(claudeKeybindings: user).keys(for: try hint("esc to interrupt"), agent: .claudeCode) == ["escape"])

        for chord in ["ctrl+shift+c", "ctrl+alt+c", "ctrl+shift+z", "ctrl+alt+d", "ctrl+shift+\\\\"] {
            let signal = bindings("""
            {"bindings": [{"context": "Chat", "bindings": {"escape": null, "\(chord)": "chat:cancel"}}]}
            """)
            #expect(
                AgentKeyHintChordResolver(claudeKeybindings: signal).keys(for: try hint("esc to interrupt"), agent: .claudeCode) == ["escape"],
                "\(chord)"
            )
        }
    }

    @Test func otherAgentsUseThePrintedChord() throws {
        let user = bindings("""
        {"bindings": [{"context": "Global", "bindings": {"ctrl+t": "app:toggleTranscript"}}]}
        """)
        #expect(AgentKeyHintChordResolver(claudeKeybindings: user).keys(for: try hint("ctrl+o to expand", .codex), agent: .codex) == ["ctrl+o"])
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

    @Test func hoverChecksTheFileAtMostOncePerMaxAge() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("keybindings.json")
        let clock = ManualClock()
        let file = ClaudeCodeKeybindingsFile(url: url, now: { clock.now })
        #expect(file.current(maxAge: 5) == .empty)

        try Data(#"{"bindings":[{"context":"Global","bindings":{"ctrl+t":"app:toggleTranscript"}}]}"#.utf8).write(to: url)
        clock.now = 4
        #expect(file.current(maxAge: 5) == .empty, "Within maxAge the cached bindings stand")
        #expect(file.current().keysByAction["app:toggleTranscript"] == [["ctrl+t"]], "A click always checks")

        try Data(#"{"bindings":[{"context":"Global","bindings":{"ctrl+y":"app:toggleTranscript"}}]}"#.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        clock.now = 8
        #expect(file.current(maxAge: 5).keysByAction["app:toggleTranscript"] == [["ctrl+t"]])
        clock.now = 10
        #expect(file.current(maxAge: 5).keysByAction["app:toggleTranscript"] == [["ctrl+y"]])
    }
}

private final class ManualClock: @unchecked Sendable {
    var now: TimeInterval = 0
}

@Suite("Agent key hint live region")
struct AgentKeyHintLiveRegionTests {
    @Test func rowsFromJustAboveTheCursorDownAreLive() {
        let region = AgentKeyHintLiveRegion(viewportAtBottom: true, cursorRow: 40)
        #expect(region.contains(row: 40 - AgentKeyHintLiveRegion.rowsAboveCursor))
        #expect(region.contains(row: 40))
        #expect(region.contains(row: 49), "Footer rows below the cursor")
        #expect(!region.contains(row: 40 - AgentKeyHintLiveRegion.rowsAboveCursor - 1))
        #expect(!region.contains(row: 5))
    }

    @Test func aCursorNearTheTopKeepsEveryRowFromTheTopLive() {
        #expect(AgentKeyHintLiveRegion(viewportAtBottom: true, cursorRow: 2).contains(row: 0))
    }

    @Test func nothingIsLiveInScrollbackOrWithTheCursorOffScreen() {
        #expect(AgentKeyHintLiveRegion(viewportAtBottom: false, cursorRow: 40).firstRow == nil)
        #expect(AgentKeyHintLiveRegion(viewportAtBottom: true, cursorRow: nil).firstRow == nil)
        #expect(!AgentKeyHintLiveRegion(viewportAtBottom: false, cursorRow: 40).contains(row: 45))
    }
}

@Suite("Agent key hint deferred press")
struct AgentKeyHintDeferredPressTests {
    @Test func aSingleClickPressesOnceTheDoubleClickIntervalPasses() {
        var press = AgentKeyHintDeferredPress(delay: 0.5)
        let due = press.release(at: 10)
        let early = press.fire(at: 10.4)
        let onTime = press.fire(at: 10.5)
        let again = press.fire(at: 11)
        #expect(due == 10.5)
        #expect(!early)
        #expect(onTime)
        #expect(!again, "A click presses once")
    }

    @Test func aDoubleOrTripleClickPressesNothing() {
        var press = AgentKeyHintDeferredPress(delay: 0.5)
        press.release(at: 10)
        let secondPress = press.press(clickCount: 2)
        let afterDouble = press.fire(at: 10.5)
        let thirdPress = press.press(clickCount: 3)
        let afterTriple = press.fire(at: 11)
        #expect(!secondPress)
        #expect(!afterDouble)
        #expect(!thirdPress)
        #expect(!afterTriple)
    }

    @Test func aNewSingleClickCompletesThePendingOne() {
        var press = AgentKeyHintDeferredPress(delay: 0.5)
        press.release(at: 10)
        let newClick = press.press(clickCount: 1)
        let timer = press.fire(at: 10.5)
        let anotherClick = press.press(clickCount: 1)
        #expect(newClick)
        #expect(!timer, "It already pressed")
        #expect(!anotherClick, "Nothing is pending")
    }

    @Test func aLaterReleaseMovesTheDeadline() {
        var press = AgentKeyHintDeferredPress(delay: 0.5)
        press.release(at: 10)
        press.release(at: 10.3)
        let firstTimer = press.fire(at: 10.5)
        let secondTimer = press.fire(at: 10.8)
        #expect(!firstTimer, "The first release's timer finds the click not yet due")
        #expect(secondTimer)
    }
}

@Suite("Agent key hint click policy")
struct AgentKeyHintClickPolicyTests {
    @Test func plainClickPressesUnlessTheAgentOwnsTheMouse() {
        #expect(AgentKeyHintClickPolicy(mouseCaptured: false, commandHeld: false, otherModifierHeld: false).pressesHint)
        #expect(!AgentKeyHintClickPolicy(mouseCaptured: true, commandHeld: false, otherModifierHeld: false).pressesHint)
        #expect(AgentKeyHintClickPolicy(mouseCaptured: true, commandHeld: true, otherModifierHeld: false).pressesHint)
        #expect(AgentKeyHintClickPolicy(mouseCaptured: false, commandHeld: true, otherModifierHeld: false).pressesHint)
        #expect(!AgentKeyHintClickPolicy(mouseCaptured: false, commandHeld: false, otherModifierHeld: true).pressesHint)
        #expect(!AgentKeyHintClickPolicy(mouseCaptured: true, commandHeld: true, otherModifierHeld: true).pressesHint)
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
        #expect(String(terminalLegacyEncodingOfNamedKey: key) == text)
    }

    @Test(arguments: ["alt+x", "ctrl+shift+o", "pageup", "f1", "ctrl+?"])
    func skipsKeysWithoutALegacyEncoding(key: String) {
        #expect(String(terminalLegacyEncodingOfNamedKey: key) == nil)
    }
}
