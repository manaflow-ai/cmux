import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextFocusUI
import CmuxNextTestSupport
import Foundation
import Testing

/// #24913 (fuzz seed 21 on macOS 14 and 15): a 10 s main-thread stall inside an AppKit key-window
/// change that `FocusEffectApplier` drove. Each key change walks the cmux window's whole view tree,
/// so one focus request makes at most one: focusing a Chromium page grants it (its page window takes
/// the keys) without first handing the keys to the cmux window, and the cmux window takes the keys
/// back only from another key window. Drives `ChildPageFocus` with a key-window recorder and pages
/// whose grant makes their page window key, as CEF's `SetFocus` does.
@MainActor @Suite(.serialized, .closesItsWindows)
struct ChildPageFocusKeyChangeTests {
    /// The app's key window, with every change counted.
    final class Keys: KeyWindowSwitching {
        var keyWindow: NSWindow?
        private(set) var changes: [String] = []
        let names: [ObjectIdentifier: String]

        init(_ names: [NSWindow: String]) {
            self.names = Dictionary(uniqueKeysWithValues: names.map { (ObjectIdentifier($0.key), $0.value) })
        }

        func isKey(_ window: NSWindow) -> Bool { keyWindow === window }

        func makeKey(_ window: NSWindow) {
            guard keyWindow !== window else { return }
            keyWindow = window
            changes.append(names[ObjectIdentifier(window)] ?? "?")
        }
    }

    final class World {
        let cmux = World.window(), pageA = World.window(), pageB = World.window()
        let keys: Keys
        let a: MockBrowserTab, b: MockBrowserTab
        var focus: ChildPageFocus!
        /// Runs inside a grant, after its page window took the keys (AppKit's didBecomeKey).
        var duringGrant: (() -> Void)?
        private(set) var focusCalls: [(String, Bool)] = []
        /// Pages whose window the fork ordered out (host hidden, empty or out of its window): they cannot take keys.
        var hidden: Set<String> = []
        /// The pages that kept their ask while they could not take the keys.
        private(set) var keptAsks: [String] = []
        /// The pages that dropped a kept ask (``ChildPageFocus/replace(with:)``).
        private(set) var droppedAsks: [String] = []

        init() {
            keys = Keys([cmux: "cmux", pageA: "pageA", pageB: "pageB"])
            let engine = MockBrowserEngine(kind: .cef)
            a = engine.makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://a.example")))
            b = engine.makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://b.example")))
            focus = ChildPageFocus(keys: keys, canTakeKeys: { [weak self] page in
                guard let self else { return true }
                return !self.hidden.contains(page === self.a ? "a" : "b")
            }, keepAsk: { [weak self] page in
                guard let self else { return }
                self.keptAsks.append(page === self.a ? "a" : "b")
            }, dropAsk: { [weak self] page in
                guard let self else { return }
                self.droppedAsks.append(page === self.a ? "a" : "b")
            }) { [weak self] page, focused in
                guard let self else { return }
                let isA = page === self.a
                self.focusCalls.append((isA ? "a" : "b", focused))
                (page as? MockBrowserTab)?.setFocused(focused)
                // CEF's SetFocus(true) makes the page's child window key.
                guard focused else { return }
                self.keys.makeKey(isA ? self.pageA : self.pageB)
                self.duringGrant?()
            }
        }

        static func window() -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless],
                                  backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            return window
        }

        /// The cmux window takes the keys back from a key Chromium page window (the rule accepts it).
        func reclaim() { focus.reclaim(into: cmux) { $0 === pageA || $0 === pageB } }
    }

    @Test func focusingAnotherPageMakesOneKeyChange() {
        let world = World()
        defer { [world.cmux, world.pageA, world.pageB].forEach { $0.closeAfterTest() } }
        world.focus.focus(world.a)
        #expect(world.keys.changes == ["pageA"])
        world.focus.focus(world.b)
        #expect(world.keys.changes == ["pageA", "pageB"], "page A to page B made \(world.keys.changes.dropFirst()), not one change to page B")
        #expect(world.focusCalls.map { "\($0.0)\($0.1)" } == ["atrue", "afalse", "btrue"])
        #expect(world.focus.page === world.b)
    }

    @Test func focusingThePageThatHasFocusMakesNoKeyChange() {
        let world = World()
        defer { [world.cmux, world.pageA, world.pageB].forEach { $0.closeAfterTest() } }
        world.focus.focus(world.a)
        world.focus.focus(world.a)
        #expect(world.keys.changes == ["pageA"])
        #expect(world.focusCalls.count == 1)
    }

    /// AppKit's didBecomeKey runs inside the grant; a re-apply there must not grant again (ping-pong).
    @Test func aReapplyInsideTheGrantDoesNotGrantAgain() {
        let world = World()
        defer { [world.cmux, world.pageA, world.pageB].forEach { $0.closeAfterTest() } }
        world.duringGrant = { [weak world] in
            guard let world else { return }
            world.focus.focus(world.b)
            world.reclaim()
        }
        world.focus.focus(world.b)
        #expect(world.keys.changes == ["pageB"], "one focus request made \(world.keys.changes)")
        #expect(world.focusCalls.count == 1)
    }

    /// Focus leaves the page inside its grant (the model moved on to a terminal): the page blurs and
    /// the cmux window takes the keys back, grant or not.
    @Test func reclaimInsideTheGrantAfterThePageBlurredTakesTheKeysBack() {
        let world = World()
        defer { [world.cmux, world.pageA, world.pageB].forEach { $0.closeAfterTest() } }
        world.duringGrant = { [weak world] in
            guard let world else { return }
            world.focus.blurPage()
            world.reclaim()
        }
        world.focus.focus(world.b)
        #expect(world.keys.changes == ["pageB", "cmux"], "the keys stayed on the blurred page: \(world.keys.changes)")
        #expect(world.focus.page == nil)
    }

    @Test func reclaimMakesNoKeyChangeWhenTheCmuxWindowIsKey() {
        let world = World()
        defer { [world.cmux, world.pageA, world.pageB].forEach { $0.closeAfterTest() } }
        world.keys.makeKey(world.cmux)
        world.reclaim()
        world.reclaim()
        #expect(world.keys.changes == ["cmux"])
    }

    @Test func reclaimMakesNoKeyChangeWhileNoWindowIsKey() {
        let world = World()
        defer { [world.cmux, world.pageA, world.pageB].forEach { $0.closeAfterTest() } }
        world.reclaim()
        #expect(world.keys.changes.isEmpty, "an inactive app's window took the keys")
    }

    /// Cmd-N on a Chromium New Tab page: the page readied in its provisional pane and took the keys,
    /// then moved to its real pane, whose present gave the cmux window the keys. The re-apply found
    /// the page focused and granted nothing: no caret, typing went to the cmux window.
    @Test func aPageThatLostTheKeysToTheCmuxWindowIsGrantedAgain() {
        let world = World()
        defer { [world.cmux, world.pageA, world.pageB].forEach { $0.closeAfterTest() } }
        world.focus.focus(world.a)
        world.keys.makeKey(world.cmux) // the page window was presented again
        #expect(world.focus.keysReturned(to: world.cmux))
        #expect(world.focus.page == nil)
        world.focus.focus(world.a) // the model re-applies its target
        #expect(world.keys.changes == ["pageA", "cmux", "pageA"], "the page never got the keys back: \(world.keys.changes)")
        #expect(world.focusCalls.map { "\($0.0)\($0.1)" } == ["atrue", "afalse", "atrue"])
    }

    /// INSTANT OWNER (#36474): a Cmd-N made 31 key-window changes. Each frame change of the pane host of the
    /// focused Chromium page that left it hidden or empty made the fork order the page window out (AppKit gave the keys
    /// to the cmux window), and this tracker then blurred the page and the model granted it again at once, to a window
    /// that could not show. A page that cannot take the keys keeps its ask, with no blur and no grant: the fork's own
    /// order-out is the one change, and the page is granted once when it shows again.
    @Test func keysReturnedFromAPageThatCannotTakeThemKeepItsAskWithNoBlurAndNoGrant() {
        let world = World()
        defer { [world.cmux, world.pageA, world.pageB].forEach { $0.closeAfterTest() } }
        world.focus.focus(world.a)
        world.hidden = ["a"]
        world.keys.makeKey(world.cmux) // the fork ordered the hidden page's window out
        let returned = world.focus.keysReturned(to: world.cmux)
        #expect(!returned, "the page that cannot take the keys was blurred, and the model re-applied its target at once")
        #expect(world.focus.page === world.a, "the page lost its focus while it could not show")
        #expect(world.keptAsks == ["a"], "the page kept no ask: \(world.keptAsks)")
        #expect(world.focusCalls.map { "\($0.0)\($0.1)" } == ["atrue"], "focus calls: \(world.focusCalls.map { "\($0.0)\($0.1)" })")
        #expect(world.keys.changes == ["pageA", "cmux"], "key changes: \(world.keys.changes) (want the fork's order-out only)")
    }

    /// #36474 review finding 1: the focus applier replaces the focused page with no blur when the keyboard moves to a
    /// docked DevTools or a click chooses another page. The old page drops its kept ask there, so it cannot take the keys
    /// back later when its host gets an area; the new page's ask is never dropped, and a replace with the same page drops
    /// nothing. Without the drop, page A (host empty, ask kept) took the keys from page B once A's host got its area.
    @Test func replacingTheFocusedPageDropsOnlyTheOldPagesKeptAsk() {
        let world = World()
        defer { [world.cmux, world.pageA, world.pageB].forEach { $0.closeAfterTest() } }
        world.focus.focus(world.a)
        world.hidden = ["a"]
        world.keys.makeKey(world.cmux)
        _ = world.focus.keysReturned(to: world.cmux) // page A keeps its ask while its host is empty
        let keyChanges = world.keys.changes

        world.focus.replace(with: world.b)
        #expect(world.droppedAsks == ["a"], "the replaced page's kept ask was not dropped: \(world.droppedAsks)")
        #expect(world.focus.page === world.b)
        world.focus.replace(with: world.b)
        #expect(world.droppedAsks == ["a"], "a replace with the focused page dropped an ask again: \(world.droppedAsks)")
        world.focus.replace(with: nil)
        #expect(world.droppedAsks == ["a", "b"], "the page focus left with no blur kept its ask: \(world.droppedAsks)")
        #expect(world.focus.page == nil)
        #expect(world.keys.changes == keyChanges, "a replace changed the key window: \(world.keys.changes)")
    }

    @Test func keysReturnedChangesNothingWhileThePageWindowIsKey() {
        let world = World()
        defer { [world.cmux, world.pageA, world.pageB].forEach { $0.closeAfterTest() } }
        world.focus.focus(world.a)
        #expect(!world.focus.keysReturned(to: world.cmux))
        #expect(world.focus.page === world.a)
        #expect(world.focusCalls.count == 1)
    }

    @Test func keysReturnedChangesNothingWithNoFocusedPage() {
        let world = World()
        defer { [world.cmux, world.pageA, world.pageB].forEach { $0.closeAfterTest() } }
        world.keys.makeKey(world.cmux)
        #expect(!world.focus.keysReturned(to: world.cmux))
        #expect(world.focusCalls.isEmpty)
    }

    /// A key change inside the grant is the grant's own: no blur and no second grant (ping-pong).
    @Test func keysReturnedInsideTheGrantChangesNothing() {
        let world = World()
        defer { [world.cmux, world.pageA, world.pageB].forEach { $0.closeAfterTest() } }
        var returned: Bool?
        world.duringGrant = { [weak world] in
            guard let world else { return }
            world.keys.makeKey(world.cmux)
            returned = world.focus.keysReturned(to: world.cmux)
        }
        world.focus.focus(world.a)
        #expect(returned == false)
        #expect(world.focus.page === world.a)
        #expect(world.focusCalls.count == 1)
    }

    /// Focus leaves the page for a target in the cmux window (a terminal): one change, back to cmux.
    @Test func leavingThePageMakesOneKeyChange() {
        let world = World()
        defer { [world.cmux, world.pageA, world.pageB].forEach { $0.closeAfterTest() } }
        world.focus.focus(world.a)
        world.focus.blurPage()
        world.reclaim()
        #expect(world.keys.changes == ["pageA", "cmux"])
        #expect(world.focus.page == nil)
    }
}
