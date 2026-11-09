import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextFocus
import Testing

/// The titlebar's Back / Forward buttons (focus history, `focusHistoryBack` /
/// `focusHistoryForward`) have their own default keys, Opt-Cmd-, / Opt-Cmd-. (Lawrence
/// 2026-11-07: "we need a new shortcut for back and forth by default for top left one not browser
/// one"). Cmd-[ / Cmd-] are a web page's own Back / Forward and Ctrl-- is readline undo in a
/// terminal, so before this neither reached the titlebar history from those panes. The new keys run
/// it in every pane, and the buttons' tooltips and the Window menu show them.
@MainActor @Suite struct TitlebarHistoryKeysTests {
    static let registry: ActionRegistry = {
        let registry = ActionRegistry.standard()
        for descriptor in registry.descriptors { registry.bind(descriptor.id, invoke: { _ in }) }
        return registry
    }()

    /// 0 web page, 1 address bar, 2 terminal, 3 agent chat, 4 sidebar.
    static func focus(_ pane: Int) -> FocusState {
        var focus = FocusState()
        switch pane {
        case 0:
            focus.resolved = .browserPage(pane: "pane_page", tab: "tab_page")
            focus.context = FocusState.Context(browser: true)
        case 1:
            focus.resolved = .addressBar(pane: "pane_page", tab: "tab_page")
            focus.context = FocusState.Context(browser: true)
        case 2:
            focus.resolved = .terminal(pane: "pane_term", tab: "tab_term")
            focus.context = FocusState.Context(terminal: true)
        case 3:
            focus.resolved = .agentPage(pane: "pane_agent", tab: "tab_agent")
            focus.context = FocusState.Context(agent: true)
        default:
            focus.resolved = .sidebar
        }
        return focus
    }

    static func key(_ typed: String, _ unmodified: String, _ modifiers: NSEvent.ModifierFlags, _ scan: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 1, windowNumber: 0,
                                      context: nil, characters: typed, charactersIgnoringModifiers: unmodified,
                                      isARepeat: false, keyCode: scan))
    }

    /// What the key router does with `event` in `pane`, as text (`run(... focusHistoryBack ...)`).
    static func decision(_ event: NSEvent, in pane: Int) -> String {
        String(describing: KeyRouter(registry: registry).decide(event, focus: focus(pane), keyWindow: .content))
    }

    /// Opt-Cmd-, on a US layout: the page sees "≤", the key router reads the unmodified ",".
    @Test(arguments: 0...4) func optCmdCommaGoesBackInEveryPane(_ pane: Int) throws {
        let result = Self.decision(try Self.key("≤", ",", [.command, .option], 43), in: pane)
        #expect(result.contains("focusHistoryBack"), "pane \(pane): \(result)")
    }

    @Test(arguments: 0...4) func optCmdPeriodGoesForwardInEveryPane(_ pane: Int) throws {
        let result = Self.decision(try Self.key("≥", ".", [.command, .option], 47), in: pane)
        #expect(result.contains("focusHistoryForward"), "pane \(pane): \(result)")
    }

    /// The buttons' tooltips and the Window menu read the action's shortcut.
    @Test func theTooltipAndMenuShowTheNewKeys() {
        #expect(Self.registry.shortcutDisplay(for: "focusHistoryBack") == "⌥⌘,")
        #expect(Self.registry.shortcutDisplay(for: "focusHistoryForward") == "⌥⌘.")
    }

    /// A web page keeps Cmd-[ as its own Back.
    @Test func aWebPageKeepsCmdBracketForItsOwnHistory() throws {
        #expect(Self.decision(try Self.key("[", "[", [.command], 33), in: 0).contains("browserBack"))
    }

    /// The old keys still work where they did: Cmd-[ outside a web page, Ctrl-- outside a terminal.
    @Test func theOlderKeysStillWork() throws {
        #expect(Self.decision(try Self.key("[", "[", [.command], 33), in: 2).contains("focusHistoryBack"))
        let ctrlMinus = try Self.key("\u{1F}", "-", [.control], 27)
        #expect(Self.decision(ctrlMinus, in: 4).contains("focusHistoryBack"))
        #expect(!Self.decision(ctrlMinus, in: 2).contains("focusHistoryBack"), "Ctrl-- must stay readline undo in a terminal")
    }
}
