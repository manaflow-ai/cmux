import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextFocusUI
import Foundation
import Testing

/// #24913 (fuzz seed 21 on macOS 14 and 15): a 10 s main-thread stall inside an AppKit key-window
/// change that `FocusEffectApplier` drove. Each key change walks the cmux window's whole view tree,
/// so one focus request makes at most one: focusing a Chromium page grants it (its page window takes
/// the keys) without first handing the keys to the cmux window, and the cmux window takes the keys
/// back only from another key window. Drives `ChildPageFocus` with a key-window recorder and pages
/// whose grant makes their page window key, as CEF's `SetFocus` does.
@MainActor @Suite(.serialized)
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

        init() {
            keys = Keys([cmux: "cmux", pageA: "pageA", pageB: "pageB"])
            let engine = MockBrowserEngine(kind: .cef)
            a = engine.makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://a.example"), origin: .user))
            b = engine.makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://b.example"), origin: .user))
            focus = ChildPageFocus(keys: keys) { [weak self] page, focused in
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
        world.focus.focus(world.a)
        #expect(world.keys.changes == ["pageA"])
        world.focus.focus(world.b)
        #expect(world.keys.changes == ["pageA", "pageB"], "page A to page B made \(world.keys.changes.dropFirst()), not one change to page B")
        #expect(world.focusCalls.map { "\($0.0)\($0.1)" } == ["atrue", "afalse", "btrue"])
        #expect(world.focus.page === world.b)
    }

    @Test func focusingThePageThatHasFocusMakesNoKeyChange() {
        let world = World()
        world.focus.focus(world.a)
        world.focus.focus(world.a)
        #expect(world.keys.changes == ["pageA"])
        #expect(world.focusCalls.count == 1)
    }

    /// AppKit's didBecomeKey runs inside the grant; a re-apply there must not grant again (ping-pong).
    @Test func aReapplyInsideTheGrantDoesNotGrantAgain() {
        let world = World()
        world.duringGrant = { [weak world] in
            guard let world else { return }
            world.focus.focus(world.b)
            world.reclaim()
        }
        world.focus.focus(world.b)
        #expect(world.keys.changes == ["pageB"], "one focus request made \(world.keys.changes)")
        #expect(world.focusCalls.count == 1)
    }

    @Test func reclaimMakesNoKeyChangeWhenTheCmuxWindowIsKey() {
        let world = World()
        world.keys.makeKey(world.cmux)
        world.reclaim()
        world.reclaim()
        #expect(world.keys.changes == ["cmux"])
    }

    @Test func reclaimMakesNoKeyChangeWhileNoWindowIsKey() {
        let world = World()
        world.reclaim()
        #expect(world.keys.changes.isEmpty, "an inactive app's window took the keys")
    }

    /// Focus leaves the page for a target in the cmux window (a terminal): one change, back to cmux.
    @Test func leavingThePageMakesOneKeyChange() {
        let world = World()
        world.focus.focus(world.a)
        world.focus.blurPage()
        world.reclaim()
        #expect(world.keys.changes == ["pageA", "cmux"])
        #expect(world.focus.page == nil)
    }
}
