import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// PANE-FOCUS-RESIZE-KEYS-AND-GHOSTTY-KEYBINDS through the key dispatcher:
/// Cmd-Ctrl-H/J/K/L move focus between panes and Ctrl-Shift-H/J/K/L resize
/// the focused pane, in a terminal and in a page.
@MainActor
struct PaneKeyDefaultsTests {
    typealias K = KeyInterceptionTests
    typealias M = KeyOwnershipMatrixTests

    static let letters: [(key: String, code: UInt16, focus: ActionID, resize: ActionID)] = [
        ("h", 4, "focusLeft", "resizePaneLeft"), ("j", 38, "focusDown", "resizePaneDown"),
        ("k", 40, "focusUp", "resizePaneUp"), ("l", 37, "focusRight", "resizePaneRight"),
    ]

    static var surfaces: [M.Surface] {
        [M.Surface(name: "terminal", focus: M.terminal), M.Surface(name: "page", focus: M.page)]
    }

    @Test func commandControlLettersFocusThePaneInThatDirection() throws {
        let services = ActionBindingCoverageTests.boundServices()
        for letter in Self.letters {
            let event = try K.key(letter.key, keyCode: letter.code, [.command, .control])
            for surface in Self.surfaces {
                #expect(M.owner(services, event, surface) == .action(letter.focus), "\(surface.name) Cmd-Ctrl-\(letter.key)")
            }
        }
    }

    @Test func controlShiftLettersResizeTheFocusedPane() throws {
        let services = ActionBindingCoverageTests.boundServices()
        for letter in Self.letters {
            let event = try K.key(letter.key.uppercased(), keyCode: letter.code, [.control, .shift])
            for surface in Self.surfaces {
                #expect(M.owner(services, event, surface) == .action(letter.resize), "\(surface.name) Ctrl-Shift-\(letter.key)")
            }
        }
    }

    /// Cmd-Ctrl-L runs Focus Pane Right (the handler, not only the table).
    @Test func commandControlLRunsFocusRight() throws {
        let services = ActionBindingCoverageTests.boundServices()
        var ran: [ActionID] = []
        services.registry.bind("focusRight", invoke: { _ in ran.append("focusRight") })
        services.registry.bind("resizePaneRight", invoke: { _ in ran.append("resizePaneRight") })
        let focus = try K.key("l", keyCode: 37, [.command, .control])
        guard case .run(let candidate) = services.keyRouter.decide(focus, focus: M.page, keyWindow: .content) else {
            Issue.record("Cmd-Ctrl-L did not run an action")
            return
        }
        #expect(services.registry.perform(candidate.id))
        #expect(ran == ["focusRight"])
    }
}

/// PANE-FOCUS-RESIZE-KEYS-AND-GHOSTTY-KEYBINDS amendment 3: focus history
/// Ctrl-- / Ctrl-Shift-- runs everywhere except a focused terminal, where
/// Ctrl-_ (readline/emacs undo) and Ctrl-- reach the terminal program.
@MainActor
struct FocusHistoryTerminalKeyTests {
    typealias K = KeyInterceptionTests
    typealias M = KeyOwnershipMatrixTests

    static func keys() throws -> [(name: String, event: NSEvent, action: ActionID)] {
        [
            ("ctrl-minus", try K.key("-", keyCode: 27, [.control]), "focusHistoryBack"),
            ("ctrl-shift-minus", try K.key("_", keyCode: 27, [.control, .shift]), "focusHistoryForward"),
        ]
    }

    @Test func inAFocusedTerminalTheKeysReachTheTerminal() throws {
        let services = ActionBindingCoverageTests.boundServices()
        for key in try Self.keys() {
            #expect(M.owner(services, key.event, M.Surface(name: "terminal", focus: M.terminal)) == .surface, "\(key.name)")
        }
    }

    @Test func elsewhereTheKeysRunFocusHistory() throws {
        let services = ActionBindingCoverageTests.boundServices()
        let surfaces = [
            M.Surface(name: "page", focus: M.page),
            M.Surface(name: "sidebar", focus: M.focused(.terminal, tab: "t1", target: .sidebar(keyboard: false))),
        ]
        for key in try Self.keys() {
            for surface in surfaces {
                #expect(M.owner(services, key.event, surface) == .action(key.action), "\(surface.name) \(key.name)")
            }
        }
    }
}
