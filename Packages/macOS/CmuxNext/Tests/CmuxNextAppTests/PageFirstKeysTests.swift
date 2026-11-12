import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextFocus
import Testing

/// cmux shortcuts win over a web page unless browser focus mode is on (Lawrence 2026-11-11: "im in linear
/// and cmd b goes to linear itself instead of toggling left sidebar ... we should only direct keyboard
/// shortcuts into the website itself if focus mode for website is on, else all keyboard shortcuts should go
/// to cmux itself"). Only Find and its neighbors stay page-first in a Chromium tab (Lawrence 2026-10-23,
/// Google Sheets' own Cmd-F): cmux runs Find only when Chromium reports that the page did not handle the
/// key (no `preventDefault`). Every other cmux shortcut (Cmd-B, Cmd-I, Cmd-R, Cmd-T, Cmd-1...) runs first.
@MainActor @Suite struct PageFirstKeysTests {
    nonisolated struct Key: CustomStringConvertible, Sendable {
        var name: String
        var characters: String
        var keyCode: UInt16
        var modifiers: NSEvent.ModifierFlags = [.command]
        var description: String { name }
    }

    /// Keys a page may own: Find and its neighbors.
    nonisolated static let pageOwnedKeys: [Key] = [
        Key(name: "Cmd-F", characters: "f", keyCode: 3),
        Key(name: "Cmd-G", characters: "g", keyCode: 5),
        Key(name: "Opt-Cmd-G", characters: "g", keyCode: 5, modifiers: [.command, .option]),
    ]

    /// Chords a page also uses (Cmd-B Bold and Linear's own Cmd-B, Cmd-I Italic) bound to a cmux
    /// navigation action, and the browser's
    /// content chords (Reload, Zoom In, Back): cmux runs them before the page sees them.
    nonisolated static let cmuxKeys: [Key] = [
        Key(name: "Cmd-B", characters: "b", keyCode: 11),
        Key(name: "Cmd-I", characters: "i", keyCode: 34),
        Key(name: "Cmd-R", characters: "r", keyCode: 15),
        Key(name: "Cmd-=", characters: "=", keyCode: 24),
        Key(name: "Cmd-[", characters: "[", keyCode: 33),
    ]

    /// Window-level keys: cmux runs them before any page.
    nonisolated static let windowKeys: [Key] = [
        Key(name: "Cmd-T", characters: "t", keyCode: 17),
        Key(name: "Cmd-W", characters: "w", keyCode: 13),
        Key(name: "Cmd-N", characters: "n", keyCode: 45),
    ] + zip(1...9, [18, 19, 20, 21, 23, 22, 26, 28, 25] as [UInt16]).map { Key(name: "Cmd-\($0)", characters: "\($0)", keyCode: $1) }

    /// Every action bound, recording what ran.
    final class Ran {
        var ids: [ActionID] = []
    }

    static func registry(recording ran: Ran = Ran()) -> ActionRegistry {
        let registry = ActionRegistry.standard()
        for descriptor in registry.descriptors {
            let id = descriptor.id
            registry.bind(id, invoke: { _ in ran.ids.append(id) })
        }
        return registry
    }

    static func event(_ key: Key, timestamp: TimeInterval = 1) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: key.modifiers, timestamp: timestamp, windowNumber: 0,
                                      context: nil, characters: key.characters, charactersIgnoringModifiers: key.characters,
                                      isARepeat: false, keyCode: key.keyCode))
    }

    static var pageFocus: FocusState {
        var focus = FocusState()
        focus.resolved = .browserPage(pane: "pane_page", tab: "tab_page")
        focus.context = FocusState.Context(browser: true)
        return focus
    }

    /// A Chromium page: it reports the keys it did not handle.
    static let chromium = KeyRouter.Facts(pageReportsUnhandledKeys: true)

    /// Kept alive for the whole run: the router holds its registry unowned.
    static let sharedRegistry = registry()

    static func decision(_ key: Key, facts: KeyRouter.Facts) throws -> KeyRouter.Decision {
        KeyRouter(registry: sharedRegistry).decide(try event(key), focus: pageFocus, keyWindow: .content, facts: facts)
    }

    /// Cmd-F in a Chromium page goes to the page first, with cmux's Find held for after it.
    @Test(arguments: pageOwnedKeys) func chromiumPageGetsTheKeyFirst(_ key: Key) throws {
        guard case .offerToPage(let candidate) = try Self.decision(key, facts: Self.chromium) else {
            Issue.record("\(key) ran a cmux action before the page saw it")
            return
        }
        #expect(["find", "findNext", "findPrevious"].contains(candidate.id.rawValue))
    }

    /// Cmd-B in a Chromium page toggles the cmux sidebar at once (Linear takes Cmd-B for itself with
    /// `preventDefault`, so a page-first offer never ran Toggle Sidebar there); the other cmux chords too.
    @Test(arguments: cmuxKeys) func cmuxShortcutsRunBeforeAChromiumPage(_ key: Key) throws {
        guard case .run = try Self.decision(key, facts: Self.chromium) else {
            Issue.record("\(key) went to the page before cmux ran its action")
            return
        }
    }

    /// Cmd-B runs Toggle Sidebar, nothing else.
    @Test func cmdBTogglesTheSidebarInAChromiumPage() throws {
        guard case .run(let candidate) = try Self.decision(Self.cmuxKeys[0], facts: Self.chromium) else {
            Issue.record("Cmd-B did not run a cmux action in a Chromium page")
            return
        }
        #expect(candidate.id == "toggleSidebar")
    }

    /// Outside a page (a terminal has the keyboard), Cmd-B still toggles the sidebar at once.
    @Test func editingChordOutsideAPageRunsAtOnce() throws {
        var focus = FocusState()
        focus.resolved = .terminal(pane: "pane_term", tab: "tab_term")
        let decision = KeyRouter(registry: Self.sharedRegistry).decide(try Self.event(Self.cmuxKeys[0]), focus: focus,
                                                                       keyWindow: .content, facts: Self.chromium)
        guard case .run(let candidate) = decision else {
            Issue.record("Cmd-B did not run Toggle Sidebar from a terminal")
            return
        }
        #expect(candidate.id == "toggleSidebar")
    }

    /// Window-level keys never wait for the page.
    @Test(arguments: windowKeys) func windowKeysStayWithCmux(_ key: Key) throws {
        guard case .run = try Self.decision(key, facts: Self.chromium) else {
            Issue.record("\(key) did not run its cmux action first")
            return
        }
    }

    /// Shift-Cmd-L opens a new browser from a focused Chromium page as from any other pane
    /// (https://github.com/manaflow-ai/cmux/issues/32789). Opening a tab is a window key, like Chrome's
    /// reserved Cmd-T: it never waits for the page, though Shift-Cmd-L is also an editing chord.
    @Test func openBrowserRunsBeforeAChromiumPage() throws {
        let key = Key(name: "Shift-Cmd-L", characters: "L", keyCode: 37, modifiers: [.command, .shift])
        guard case .run(let candidate) = try Self.decision(key, facts: Self.chromium) else {
            Issue.record("Shift-Cmd-L waited for the page instead of opening a browser")
            return
        }
        #expect(candidate.id == "openBrowser")
    }

    /// A WebKit page reports no unhandled keys, so cmux keeps running Find first there.
    @Test func webKitPageKeepsCmuxFind() throws {
        guard case .run(let candidate) = try Self.decision(Self.pageOwnedKeys[0], facts: KeyRouter.Facts()) else {
            Issue.record("Cmd-F did not run cmux Find in a page that reports no unhandled keys")
            return
        }
        #expect(candidate.id == "find")
    }

    /// Stands for the Chromium tab the keys go to (its identity is what an offer records).
    private static let tab = NSObject()

    /// The page did not handle Cmd-F (no `preventDefault`): cmux's Find runs, once.
    @Test func unhandledKeyRunsTheHeldActionOnce() throws {
        let ran = Ran()
        let registry = Self.registry(recording: ran)
        let router = KeyRouter(registry: registry) // the router holds its registry unowned
        defer { withExtendedLifetime(registry) {} }
        let key = try Self.event(Self.pageOwnedKeys[0])
        guard case .offerToPage(let candidate) = router.decide(key, focus: Self.pageFocus, keyWindow: .content, facts: Self.chromium) else {
            Issue.record("Cmd-F was not offered to the page")
            return
        }
        let tab = ObjectIdentifier(Self.tab)
        router.offerToPage(key, candidate: candidate, context: router.keyContext(for: Self.pageFocus, facts: Self.chromium), window: "win", tab: tab)
        #expect(ran.ids.isEmpty, "Find ran before the page answered")
        #expect(router.runUnhandledPageKey(key, from: tab))
        #expect(ran.ids == ["find"])
        #expect(!router.runUnhandledPageKey(key, from: tab), "a second report ran Find again")
        #expect(ran.ids == ["find"])
    }

    /// The page handled Cmd-F (Google Sheets' own search): Chromium reports nothing for it, and the
    /// report of the next key (Cmd-G, unhandled) releases the held Find without running it, so a late
    /// report of Cmd-F runs nothing.
    @Test func handledKeyRunsNothing() throws {
        let ran = Ran()
        let registry = Self.registry(recording: ran)
        let router = KeyRouter(registry: registry) // the router holds its registry unowned
        defer { withExtendedLifetime(registry) {} }
        let context = router.keyContext(for: Self.pageFocus, facts: Self.chromium)
        let handled = try Self.event(Self.pageOwnedKeys[0], timestamp: 1)
        guard case .offerToPage(let find) = router.decide(handled, focus: Self.pageFocus, keyWindow: .content, facts: Self.chromium) else {
            Issue.record("Cmd-F was not offered to the page")
            return
        }
        let tab = ObjectIdentifier(Self.tab)
        router.offerToPage(handled, candidate: find, context: context, window: "win", tab: tab)
        let next = try Self.event(Self.pageOwnedKeys[1], timestamp: 2)
        guard case .offerToPage(let findNext) = router.decide(next, focus: Self.pageFocus, keyWindow: .content, facts: Self.chromium) else {
            Issue.record("Cmd-G was not offered to the page")
            return
        }
        router.offerToPage(next, candidate: findNext, context: context, window: "win", tab: tab)
        #expect(router.runUnhandledPageKey(next, from: tab))
        #expect(!router.runUnhandledPageKey(handled, from: tab), "a stale report ran Find")
        #expect(ran.ids == ["findNext"])
    }
}
