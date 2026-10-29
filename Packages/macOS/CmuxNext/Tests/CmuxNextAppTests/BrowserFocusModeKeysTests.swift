import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextFocus
import Testing

/// Browser focus mode hands the keyboard to the page (Lawrence 2026-10-21: "when in focus mode
/// cmd shift p still triggers cmux cmd shift p"). Every cmux shortcut goes to the page, the
/// command palette and Close Tab included; only the exit chords stay with cmux (Esc Esc, see
/// ``BrowserFocusModeEscapeExitTests``, and Toggle Browser Focus Mode), plus Quit.
/// Chromium and WebKit tabs resolve to the same `browserPage` focus, so one rule covers both.
@MainActor @Suite struct BrowserFocusModeKeysTests {
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

    /// The keys the report named, with their US-layout key codes.
    nonisolated static let pageKeys: [Key] = [
        Key(name: "Cmd-Shift-P", characters: "P", keyCode: 35, modifiers: [.command, .shift]),
        Key(name: "Cmd-P", characters: "p", keyCode: 35),
        Key(name: "Cmd-T", characters: "t", keyCode: 17),
        Key(name: "Cmd-W", characters: "w", keyCode: 13),
        Key(name: "Cmd-D", characters: "d", keyCode: 2),
    ] + zip(1...9, [18, 19, 20, 21, 23, 22, 26, 28, 25] as [UInt16]).map { Key(name: "Cmd-\($0)", characters: "\($0)", keyCode: $1) }

    static func event(_ key: Key) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: key.modifiers, timestamp: 1, windowNumber: 0,
                                      context: nil, characters: key.characters, charactersIgnoringModifiers: key.characters,
                                      isARepeat: false, keyCode: key.keyCode))
    }

    static func focus(focusMode: Bool) -> FocusState {
        var focus = FocusState()
        focus.resolved = .browserPage(pane: "pane_page", tab: "tab_page")
        focus.context = FocusState.Context(browser: true)
        if focusMode {
            focus.browserFocusMode = ["tab_page"]
            focus.isBrowserFocusModeActive = true
        }
        return focus
    }

    static func decision(_ key: Key, focusMode: Bool) throws -> KeyRouter.Decision {
        KeyRouter(registry: registry).decide(try event(key), focus: focus(focusMode: focusMode), keyWindow: .content)
    }

    /// Outside focus mode these are cmux shortcuts on a page (the test's premise).
    @Test(arguments: pageKeys) func cmuxRunsTheKeyOutsideFocusMode(_ key: Key) throws {
        guard case .run = try Self.decision(key, focusMode: false) else {
            Issue.record("\(key) is no cmux shortcut on a page")
            return
        }
    }

    /// In focus mode the page gets the key-down, and no menu item runs its action after the page.
    @Test(arguments: pageKeys) func thePageGetsTheKeyInFocusMode(_ key: Key) throws {
        let outside = try Self.decision(key, focusMode: false)
        #expect(try Self.decision(key, focusMode: true) == .deliver, "\(key) did not reach the page")
        if case .run(let candidate) = outside {
            #expect(!KeyRouter.allowsMenu(candidate.tier, id: candidate.id, focus: Self.focus(focusMode: true), keyWindow: .content),
                    "the menu still runs \(candidate.id.rawValue) for \(key)")
        }
    }

    /// The exit chord (Opt-Cmd-Return) still leaves focus mode.
    @Test func theToggleChordStillLeaves() throws {
        let key = Key(name: "Opt-Cmd-Return", characters: "\r", keyCode: 36, modifiers: [.command, .option])
        guard case .run(let candidate) = try Self.decision(key, focusMode: true) else {
            Issue.record("Opt-Cmd-Return did not run in focus mode")
            return
        }
        #expect(candidate.id == "toggleBrowserFocusMode")
    }

    /// Quit stays with the app: no page can use Cmd-Q.
    @Test func quitStillQuits() throws {
        guard case .run(let candidate) = try Self.decision(Key(name: "Cmd-Q", characters: "q", keyCode: 12), focusMode: true) else {
            Issue.record("Cmd-Q did not run in focus mode")
            return
        }
        #expect(candidate.id == "quit")
    }
}
