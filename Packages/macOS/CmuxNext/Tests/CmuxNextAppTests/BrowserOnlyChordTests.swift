import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// Cmd-[ / Cmd-] act only in a browser context (user 2026-09-30:
/// "cmd[] in terminal should do nothing ... consistency is most important
/// for keyboard shortcuts"; plans/cmux-next/focus.md section 5).
@MainActor
struct BrowserOnlyChordTests {
    typealias K = KeyInterceptionTests

    static let sidebar = FocusReducer.reduce(K.terminal, .focusTarget(.sidebar(keyboard: true), source: .keyboard)).0

    @Test func pageAddressBarAndFindBarKeepBackAndForward() throws {
        let services = BrowserChordTableTests.services()
        for key in ["[", "]"] {
            let event = try BrowserChordTableTests.bracket(key)
            for focus in [K.page, K.omnibar, K.find] {
                #expect(!services.keyRouter.consumesBrowserOnlyChord(event, focus: focus), "\(key) \(focus.resolved)")
            }
        }
    }

    @Test func terminalAndOtherContextsConsumeWithoutAnyAction() throws {
        let services = BrowserChordTableTests.services()
        var ran: [ActionID] = []
        for id: ActionID in ["browserBack", "browserForward", "focusPreviousPane", "focusNextPane", "focusHistoryBack", "focusHistoryForward"] {
            services.registry.bind(id, invoke: { _ in ran.append(id) })
        }
        services.registry.context = [.terminalFocused]
        for key in ["[", "]"] {
            let event = try BrowserChordTableTests.bracket(key)
            for focus in [K.terminal, Self.sidebar] {
                // No candidate: not Back (no browser), not Ghostty's goto_split.
                #expect(services.keyRouter.candidate(for: event, focus: focus) == nil, "\(key) \(focus.resolved)")
                #expect(services.keyRouter.consumesBrowserOnlyChord(event, focus: focus), "\(key) \(focus.resolved)")
                #expect(!services.keyRouter.routeContentKeyEquivalent(event, focus: focus))
            }
        }
        #expect(ran.isEmpty)
    }

    /// A user rebinding of page Back moves the browser-only chord with it;
    /// Cmd-[ is then an ordinary chord again (Ghostty's keybind in a terminal).
    @Test func reboundBackMovesTheConsumedChord() throws {
        let services = BrowserChordTableTests.services()
        services.registry.setShortcutOverride(Shortcut("b", modifiers: [.command, .control]), for: "browserBack")
        let bracket = try BrowserChordTableTests.bracket("[")
        #expect(!services.keyRouter.consumesBrowserOnlyChord(bracket, focus: K.terminal))
        let rebound = try K.key("b", keyCode: 11, [.command, .control])
        #expect(services.keyRouter.consumesBrowserOnlyChord(rebound, focus: K.terminal))
    }
}
