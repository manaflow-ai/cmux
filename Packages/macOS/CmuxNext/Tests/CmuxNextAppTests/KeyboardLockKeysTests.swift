import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextFocus
import Foundation
import Testing

/// Task p01-process-229: a hosted page that holds a keyboard lock in its fullscreen gets the chords
/// cmux would run (Cmd-T, Cmd-W, Cmd-1, the palette), as Chrome's KeyboardLockController gives them to a
/// fullscreen page. Ghostty's reserved split keys stay cmux's in every pane, a locked page included
/// (schemas/keybindings/ghostty-reserved-keys.json; Lawrence 2026-10-20), and so does Quit.
@MainActor @Suite struct KeyboardLockKeysTests {
    static let registry: ActionRegistry = {
        let registry = ActionRegistry.standard()
        for descriptor in registry.descriptors { registry.bind(descriptor.id, invoke: { _ in }) }
        return registry
    }()

    nonisolated struct Key: CustomStringConvertible, Sendable {
        var name: String
        var characters: String
        var keyCode: UInt16
        var modifiers: NSEvent.ModifierFlags = [.command]
        var description: String { name }
    }

    nonisolated static let pageKeys: [Key] = [
        Key(name: "Cmd-T", characters: "t", keyCode: 17),
        Key(name: "Cmd-W", characters: "w", keyCode: 13),
        Key(name: "Cmd-1", characters: "1", keyCode: 18),
        Key(name: "Cmd-Shift-P", characters: "P", keyCode: 35, modifiers: [.command, .shift]),
    ]

    nonisolated static let keptKeys: [Key] = [
        Key(name: "Cmd-D", characters: "d", keyCode: 2),
        Key(name: "Cmd-Shift-D", characters: "D", keyCode: 2, modifiers: [.command, .shift]),
        Key(name: "Cmd-Q", characters: "q", keyCode: 12),
    ]

    static func decision(_ key: Key, locked: Bool) throws -> KeyRouter.Decision {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: key.modifiers, timestamp: 1, windowNumber: 0,
                                                  context: nil, characters: key.characters,
                                                  charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.keyCode))
        var focus = FocusState()
        focus.resolved = .browserPage(pane: "pane_page", tab: "tab_page")
        focus.context = FocusState.Context(browser: true)
        var facts = KeyRouter.Facts()
        facts.pageLocksKeys = locked
        return KeyRouter(registry: registry).decide(event, focus: focus, keyWindow: .content, facts: facts)
    }

    @Test(arguments: pageKeys) func aLockedPageGetsCmuxsChords(_ key: Key) throws {
        guard case .run = try Self.decision(key, locked: false) else {
            Issue.record("\(key) is no cmux shortcut on a page")
            return
        }
        #expect(try Self.decision(key, locked: true) == .deliver, "\(key) did not reach the locked page")
    }

    @Test(arguments: keptKeys) func ghosttysSplitKeysAndQuitStayCmuxs(_ key: Key) throws {
        guard case .run(let candidate) = try Self.decision(key, locked: true) else {
            Issue.record("\(key) went to the locked page")
            return
        }
        #expect(KeyRouter.keyboardLockKeeps.contains(candidate.id))
    }

    /// The kept set is every reserved Ghostty command, read from the file the gate enforces, plus Quit.
    @Test func theKeptSetIsTheReservedKeysAndQuit() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appending(path: "schemas/keybindings/ghostty-reserved-keys.json"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try #require(object["reserved"] as? [[String: Any]])
        let commands = Set(rows.compactMap { $0["command"] as? String }.map { ActionID(rawValue: $0) })
        #expect(!commands.isEmpty)
        #expect(KeyRouter.keyboardLockKeeps == commands.union(["quit"]))
    }
}
