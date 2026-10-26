import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// Task p04-input-062 of plans/cmux-next/chrome-parity/p04-input.md: Chromium's pre-key hook
/// (`CEFRuntime.routeKey`, from `cefKeyCallback`) asks the host's router first whether the
/// dispatcher already decided the key in `sendEvent`. A decided key goes to the page with no
/// binding resolved again (no dispatcher, no focus-mode walk, no extension shortcut lookup); only a
/// key that never passed `sendEvent` (a synthetic one) runs the dispatcher, and only once. Chrome
/// decides a browser shortcut once, before the renderer (`BrowserView::PreHandleKeyboardEvent`,
/// chrome/browser/ui/views/frame/browser_view.cc).
@MainActor @Suite(.serialized) struct CEFKeyRoutingTests {
    private static let browser: Int32 = 7

    /// A router that decides like `KeyRouter`: the dispatcher marks every key it examines decided.
    @MainActor final class SpyRouter: BrowserKeyRouting {
        var decided: Set<ObjectIdentifier> = []
        /// Keys kept alive so an identity in `decided` never names a freed event.
        private var kept: [NSEvent] = []
        var decidedQuestions = 0
        var dispatches = 0
        var focusModeQuestions = 0
        var handles = false

        func decide(_ event: NSEvent) {
            kept.append(event)
            decided.insert(ObjectIdentifier(event))
        }

        func hasDecided(_ event: NSEvent) -> Bool {
            decidedQuestions += 1
            return decided.contains(ObjectIdentifier(event))
        }

        func browserTab(_ tab: any BrowserTab, keyEquivalent event: NSEvent) -> BrowserKeyDisposition {
            guard !decided.contains(ObjectIdentifier(event)) else { return .passToPage }
            dispatches += 1
            decide(event)
            return handles ? .handledByHost : .passToPage
        }

        func pageOwnsAllKeys(_ tab: any BrowserTab) -> Bool {
            focusModeQuestions += 1
            return false
        }
    }

    private static func key(_ characters: String, _ modifiers: NSEvent.ModifierFlags, keyCode: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 1, windowNumber: 0,
                                      context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: false, keyCode: keyCode))
    }

    private static func rig() throws -> (CEFRuntime, CEFTab, SpyRouter) {
        let runtime = try HostRepliesHarness.inProcessRuntime()
        let tab = HostRepliesHarness.tab(in: HostRepliesHarness.pane(runtime, profile: .default).0)
        runtime.tabsByBrowser[browser] = tab
        let router = SpyRouter()
        tab.keyRouter = router
        return (runtime, tab, router)
    }

    /// Cmd-T and Option-K the dispatcher decided in `sendEvent`: the page gets them, and the hook
    /// asks one question and resolves nothing.
    @Test func aDecidedKeyResolvesNoBindingInThePreKeyHook() throws {
        let (runtime, tab, router) = try Self.rig()
        defer { runtime.tabsByBrowser[Self.browser] = nil }
        for event in [try Self.key("t", [.command], keyCode: 17), try Self.key("k", [.option], keyCode: 40)] {
            router.decide(event)
            #expect(!runtime.routeKey(event, browser: Self.browser), "a decided key was consumed")
        }
        #expect(router.decidedQuestions == 2)
        #expect(router.dispatches == 0, "the dispatcher ran again for a decided key")
        #expect(router.focusModeQuestions == 0, "the focus-mode walk and the extension shortcut lookup ran for a decided key")
        withExtendedLifetime(tab) {}
    }

    /// A Cmd chord that never passed `sendEvent` runs the dispatcher once; Chromium offering it again
    /// finds it decided.
    @Test func aSyntheticKeyRunsTheDispatcherOnce() throws {
        let (runtime, tab, router) = try Self.rig()
        defer { runtime.tabsByBrowser[Self.browser] = nil }
        let event = try Self.key("t", [.command], keyCode: 17)
        #expect(!runtime.routeKey(event, browser: Self.browser))
        #expect(!runtime.routeKey(event, browser: Self.browser))
        #expect(router.dispatches == 1, "a synthetic key ran the dispatcher \(router.dispatches) times")
        #expect(router.focusModeQuestions == 1, "only the first offer reached the extension shortcut step")

        let handled = try Self.key("w", [.command], keyCode: 13)
        router.handles = true
        #expect(runtime.routeKey(handled, browser: Self.browser), "the dispatcher's action did not consume the key")
        #expect(router.dispatches == 2)
        withExtendedLifetime(tab) {}
    }

    /// An Option chord the dispatcher never saw skips the dispatcher (no Command or Control) and
    /// still reaches the profile's extension shortcuts.
    @Test func anUndecidedOptionChordReachesTheExtensionShortcutStep() throws {
        let (runtime, tab, router) = try Self.rig()
        defer { runtime.tabsByBrowser[Self.browser] = nil }
        #expect(!runtime.routeKey(try Self.key("k", [.option], keyCode: 40), browser: Self.browser))
        #expect(router.dispatches == 0)
        #expect(router.focusModeQuestions == 1)
        withExtendedLifetime(tab) {}
    }

    /// Typing (no Command, Control or Option) is the page's: the hook asks the router nothing.
    @Test func aTypingKeyAsksTheRouterNothing() throws {
        let (runtime, tab, router) = try Self.rig()
        defer { runtime.tabsByBrowser[Self.browser] = nil }
        #expect(!runtime.routeKey(try Self.key("a", [], keyCode: 0), browser: Self.browser))
        #expect(!runtime.routeKey(try Self.key("A", [.shift], keyCode: 0), browser: Self.browser))
        #expect(router.decidedQuestions == 0)
        #expect(router.dispatches == 0)
        #expect(router.focusModeQuestions == 0)
        withExtendedLifetime(tab) {}
    }
}
