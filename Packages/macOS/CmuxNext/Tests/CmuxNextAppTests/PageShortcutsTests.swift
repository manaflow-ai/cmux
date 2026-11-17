import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextFocus
import Testing

/// `browser.pageShortcuts` (CMUX-641, Austin 2026-11-16: Linear's Cmd-K opened cmux Search Chats). With `page`, a
/// Chromium page gets cmux's shortcuts first and cmux runs one only when the page leaves it unhandled; app and window
/// keys stay with cmux. `cmux` keeps the rule of ``PageFirstKeysTests``; `ask` runs as `cmux` but asks about the first
/// app shortcut before either gets it.
@MainActor @Suite struct PageShortcutsTests {
    typealias Key = PageFirstKeysTests.Key

    /// A Chromium page with `browser.pageShortcuts` `page`.
    static let pageFirst = KeyRouter.Facts(pageReportsUnhandledKeys: true, pageFirstShortcuts: true)
    static let cmdK = Key(name: "Cmd-K", characters: "k", keyCode: 40)

    static func decision(_ key: Key, facts: KeyRouter.Facts = pageFirst) throws -> KeyRouter.Decision {
        try PageFirstKeysTests.decision(key, facts: facts)
    }

    /// Linear's Cmd-K reaches Linear first; cmux Search Chats waits for the page to leave it unhandled.
    @Test func cmdKGoesToThePageFirst() throws {
        guard case .offerToPage(let candidate) = try Self.decision(Self.cmdK) else {
            Issue.record("Cmd-K ran a cmux action before the page saw it")
            return
        }
        #expect(candidate.id == "agentPane.searchChats")
    }

    /// With `browser.pageShortcuts` `cmux`, Cmd-K runs Search Chats at once, as before.
    @Test func cmuxFirstRunsCmdKAtOnce() throws {
        guard case .run(let candidate) = try Self.decision(Self.cmdK, facts: PageFirstKeysTests.chromium) else {
            Issue.record("Cmd-K waited for the page with cmux first")
            return
        }
        #expect(candidate.id == "agentPane.searchChats")
    }

    /// Cmd-B, Cmd-I, Reload, Zoom and Back go to the page first too.
    @Test(arguments: PageFirstKeysTests.cmuxKeys) func cmuxShortcutsGoToThePageFirst(_ key: Key) throws {
        guard case .offerToPage = try Self.decision(key) else {
            Issue.record("\(key) ran before the page saw it")
            return
        }
    }

    /// New tab, close tab, new window and Cmd-1 to Cmd-9 never wait for the page (Chrome reserves them too).
    @Test(arguments: PageFirstKeysTests.windowKeys + [
        Key(name: "Shift-Cmd-L", characters: "L", keyCode: 37, modifiers: [.command, .shift]),
        Key(name: "Shift-Cmd-P", characters: "P", keyCode: 35, modifiers: [.command, .shift]),
        Key(name: "Cmd-P", characters: "p", keyCode: 35),  // Go to Workspace, a native palette key
        Key(name: "Opt-Cmd-Return", characters: "\r", keyCode: 36, modifiers: [.command, .option]),
        Key(name: "Cmd-D", characters: "d", keyCode: 2),
        Key(name: "Shift-Cmd-D", characters: "D", keyCode: 2, modifiers: [.command, .shift]),
    ]) func appAndWindowKeysStayWithCmux(_ key: Key) throws {
        guard case .run = try Self.decision(key) else {
            Issue.record("\(key) waited for the page")
            return
        }
    }

    /// A WebKit page reports no unhandled keys: cmux runs Cmd-K first there.
    @Test func webKitPageRunsCmdKAtOnce() throws {
        guard case .run = try Self.decision(Self.cmdK, facts: KeyRouter.Facts(pageFirstShortcuts: true)) else {
            Issue.record("Cmd-K waited for a page that reports no unhandled keys")
            return
        }
    }

    static func asks(_ key: Key, facts: KeyRouter.Facts = PageFirstKeysTests.chromium, focus: FocusState = PageFirstKeysTests.pageFocus) throws -> Bool {
        let event = try PageFirstKeysTests.event(key)
        let router = KeyRouter(registry: PageFirstKeysTests.sharedRegistry)
        guard case .run(let candidate) = router.decide(event, focus: focus, keyWindow: .content, facts: facts) else { return false }
        return KeyRouter.asksAboutPageShortcut(candidate, event: event, focus: focus, facts: facts)
    }

    /// `ask` asks about Cmd-K (Search Chats) and Cmd-B (the sidebar) before Linear or cmux gets them (Austin 2026-11-18:
    /// Linear's palette opened behind the question).
    @Test func askAsksAboutAppShortcuts() throws {
        #expect(try Self.asks(Self.cmdK))
        #expect(try Self.asks(PageFirstKeysTests.cmuxKeys[0]))
    }

    /// Browser keys (Reload, Zoom, Back), app and window keys, a WebKit page and focus mode never ask.
    @Test(arguments: PageFirstKeysTests.cmuxKeys.dropFirst(2) + PageFirstKeysTests.windowKeys + [
        Key(name: "Shift-Cmd-P", characters: "P", keyCode: 35, modifiers: [.command, .shift]),
        Key(name: "Cmd-D", characters: "d", keyCode: 2),
    ]) func askLeavesOtherKeysAlone(_ key: Key) throws {
        #expect(try !Self.asks(key), "\(key) asked who gets it")
    }

    @Test func askNeedsAChromiumPageOutOfFocusMode() throws {
        #expect(try !Self.asks(Self.cmdK, facts: KeyRouter.Facts()), "a WebKit page asked")
        var focus = PageFirstKeysTests.pageFocus
        focus.isBrowserFocusModeActive = true
        #expect(try !Self.asks(Self.cmdK, focus: focus), "focus mode asked")
    }
}
