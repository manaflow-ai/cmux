import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextFocus
import CmuxNextFocusUI
import Testing

/// Page shortcuts (CMUX-641; Lawrence and Austin 2026-11-19: "shortcuts route to websites by default", "copy UTM").
/// A Chromium page gets the shortcuts it shares with cmux first, and cmux runs one only when the page leaves it
/// unhandled. Chrome's reserved keys, Cmd-L and the system tier stay with cmux. cmux mode (Cmd-Opt-Return) gives the
/// keys back to cmux (``PageFirstKeysTests``). The per-site dialog this replaces asked about every shared key before
/// the page saw it, Cmd-L on YouTube included.
@MainActor @Suite struct PageShortcutsTests {
    typealias Key = PageFirstKeysTests.Key

    static let chromium = PageFirstKeysTests.chromium
    static let cmdK = Key(name: "Cmd-K", characters: "k", keyCode: 40)

    static func decision(_ key: Key, facts: KeyRouter.Facts = chromium, focus: FocusState = PageFirstKeysTests.pageFocus) throws -> KeyRouter.Decision {
        try PageFirstKeysTests.decision(key, facts: facts, focus: focus)
    }

    /// Linear's Cmd-K reaches Linear first; cmux Search Chats waits for the page to leave it unhandled.
    @Test func cmdKGoesToThePageFirst() throws {
        guard case .offerToPage(let candidate) = try Self.decision(Self.cmdK) else {
            Issue.record("Cmd-K ran a cmux action before the page saw it")
            return
        }
        #expect(candidate.id == "agentPane.searchChats")
    }

    /// In cmux mode, Cmd-K runs Search Chats at once.
    @Test func cmuxModeRunsCmdKAtOnce() throws {
        guard case .run(let candidate) = try Self.decision(Self.cmdK, focus: PageFirstKeysTests.cmuxModeFocus) else {
            Issue.record("Cmd-K waited for the page in cmux mode")
            return
        }
        #expect(candidate.id == "agentPane.searchChats")
    }

    /// Cmd-B, Cmd-I, Reload, Zoom and Back go to the page first too, as in Chrome.
    @Test(arguments: PageFirstKeysTests.cmuxKeys) func cmuxShortcutsGoToThePageFirst(_ key: Key) throws {
        guard case .offerToPage = try Self.decision(key) else {
            Issue.record("\(key) ran before the page saw it")
            return
        }
    }

    /// Chrome's reserved keys (new tab, close tab, new window), Cmd-1 to Cmd-9, Cmd-L (always the omnibar: Austin
    /// 2026-11-19), the palettes, the cmux mode toggle and Ghostty's pane keys never wait for the page.
    @Test(arguments: PageFirstKeysTests.windowKeys + [
        Key(name: "Cmd-L", characters: "l", keyCode: 37),
        Key(name: "Shift-Cmd-L", characters: "L", keyCode: 37, modifiers: [.command, .shift]),
        Key(name: "Shift-Cmd-P", characters: "P", keyCode: 35, modifiers: [.command, .shift]),
        Key(name: "Cmd-P", characters: "p", keyCode: 35),  // Go to Workspace, a native palette key
        Key(name: "Opt-Cmd-Return", characters: "\r", keyCode: 36, modifiers: [.command, .option]),
        Key(name: "Cmd-D", characters: "d", keyCode: 2),
        Key(name: "Shift-Cmd-D", characters: "D", keyCode: 2, modifiers: [.command, .shift]),
        Key(name: "Cmd-Q", characters: "q", keyCode: 12),
    ]) func reservedKeysStayWithCmux(_ key: Key) throws {
        guard case .run = try Self.decision(key) else {
            Issue.record("\(key) waited for the page")
            return
        }
    }

    /// Cmd-L focuses the omnibar from a page, never the page's own Cmd-L.
    @Test func cmdLFocusesTheOmnibar() throws {
        guard case .run(let candidate) = try Self.decision(Key(name: "Cmd-L", characters: "l", keyCode: 37)) else {
            Issue.record("Cmd-L waited for the page")
            return
        }
        #expect(["focusBrowserAddressBar", "focusLocation"].contains(candidate.id.rawValue))
    }

    /// Opt-Cmd-Return toggles cmux mode on and off, and so does Opt-Cmd-Enter (keypad Enter, fn-Return; Lawrence
    /// 2026-11-16: AppKit reports it as U+0003 with the numeric pad flag).
    @Test(arguments: [false, true]) func theToggleRunsInBothModes(_ cmuxMode: Bool) throws {
        let focus = cmuxMode ? PageFirstKeysTests.cmuxModeFocus : PageFirstKeysTests.pageFocus
        for key in [Key(name: "Opt-Cmd-Return", characters: "\r", keyCode: 36, modifiers: [.command, .option]),
                    Key(name: "Opt-Cmd-Enter", characters: "\u{3}", keyCode: 76, modifiers: [.command, .option, .numericPad])] {
            guard case .run(let candidate) = try Self.decision(key, focus: focus) else {
                Issue.record("\(key) did not run (cmux mode \(cmuxMode))")
                continue
            }
            #expect(candidate.id == "toggleBrowserFocusMode")
        }
    }

    /// A WebKit page reports no unhandled keys: cmux runs Cmd-K first there.
    @Test func webKitPageRunsCmdKAtOnce() throws {
        guard case .run = try Self.decision(Self.cmdK, facts: KeyRouter.Facts()) else {
            Issue.record("Cmd-K waited for a page that reports no unhandled keys")
            return
        }
    }

    /// The one-time notice is for app shortcuts a page keeps: Cmd-K (Search Chats), Cmd-B (the sidebar). Not Find,
    /// which pages always had first, not a browser key that does the same job in both, not a reserved key.
    @Test func noticeIsForAppShortcutsOnly() {
        #expect(PageShortcutRoute(id: "agentPane.searchChats", tier: .navigation).isAppShortcut)
        #expect(PageShortcutRoute(id: "toggleSidebar", tier: .navigation).isAppShortcut)
        #expect(!PageShortcutRoute(id: "find", tier: .content).isAppShortcut)
        #expect(!PageShortcutRoute(id: "browser.reload", tier: .content).isAppShortcut)
        #expect(!PageShortcutRoute(id: "focusBrowserAddressBar", tier: .navigation).isAppShortcut)
        #expect(!PageShortcutRoute(id: "closeTab", tier: .system).isAppShortcut)
    }

    /// The page kept Cmd-K (no unhandled report): the offer still holds it, which the notice reads; a report releases it.
    @Test func anOfferHoldsTheKeyUntilItsReport() throws {
        var offer = PageFirstKeyOffer<Int>()
        let key = try PageFirstKeysTests.event(Self.cmdK)
        let tab = ObjectIdentifier(NSObject.self)
        offer.offer(key, 1, tab: tab)
        #expect(offer.holds(PageFirstKeyOffer<Int>.Signature(key)))
        #expect(offer.take(key, from: tab) == 1)
        #expect(!offer.holds(PageFirstKeyOffer<Int>.Signature(key)))
    }
}
