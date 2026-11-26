public import AppKit

/// The child-window page a cmux window gave focus to, and the key-window changes focusing one makes
/// (issue #24913).
///
/// A Chromium page shows in a child window that has the keys while its page has focus: giving the
/// page focus (CEF's `SetFocus`) makes that window key. Each key-window change makes AppKit walk both
/// windows' whole view trees and may wait for the input method server; on macOS 14, 15 and 26 one
/// change took over 10 s. So one focus request makes at most one change:
///
/// - focusing another page blurs the old one and grants the new one, without handing the keys to the
///   cmux window in between (that was two changes: cmux window key, then page window key);
/// - the keys come back to the cmux window (``reclaim(into:when:)``) only when another window has them.
///
/// ```swift
/// let focus = ChildPageFocus(keys: AppKitKeyWindows()) { page, focused in
///     (page as? any BrowserTab)?.setFocused(focused)
/// }
/// focus.focus(page)        // one key change: the page window takes the keys
/// focus.blurPage()         // no key change
/// focus.reclaim(into: window) { $0.parent === window }
/// ```
///
/// A page is any object (the app passes its browser tabs; a test passes mock tabs).
public final class ChildPageFocus {
    /// The page this window gave focus to (blurred when focus leaves it), held weakly.
    public weak var page: AnyObject?
    /// A grant is running (``focus(_:)``).
    private var granting = false
    private let keys: any KeyWindowSwitching
    /// Gives (true) or takes (false) a page's focus; giving a Chromium page focus makes its window key.
    private let setFocus: (AnyObject, Bool) -> Void
    /// Whether a page's window can hold the keys now (shown, in a window, not empty).
    private let canTakeKeys: (AnyObject) -> Bool
    /// The page keeps its ask, granted once it can take the keys again.
    private let keepAsk: (AnyObject) -> Void
    /// A page that is no longer the focused one drops a kept ask (``replace(with:)``).
    private let dropAsk: (AnyObject) -> Void

    /// A tracker with no focused page.
    ///
    /// - Parameters:
    ///   - keys: The key window: ``AppKitKeyWindows`` in the app, a recorder in tests.
    ///   - canTakeKeys: Whether a page's window can hold the keys now (default: always).
    ///   - keepAsk: The page keeps its focus ask, to be granted when it can take the keys again (default: nothing).
    ///   - dropAsk: The page drops a kept ask: it is no longer the focused page (default: nothing).
    ///   - setFocus: Gives (`true`) or takes (`false`) a page's focus.
    public init(keys: any KeyWindowSwitching, canTakeKeys: @escaping (AnyObject) -> Bool = { _ in true },
                keepAsk: @escaping (AnyObject) -> Void = { _ in }, dropAsk: @escaping (AnyObject) -> Void = { _ in },
                setFocus: @escaping (AnyObject, Bool) -> Void) {
        self.keys = keys
        self.canTakeKeys = canTakeKeys
        self.keepAsk = keepAsk
        self.dropAsk = dropAsk
        self.setFocus = setFocus
    }

    /// `next` takes focus, and with it the keys (the one key change).
    ///
    /// The page focused before loses focus first, with no key change. Nothing happens when `next`
    /// has focus already. `next` is recorded before the grant, so a re-apply inside it (AppKit's
    /// didBecomeKey) finds it focused and grants nothing again.
    ///
    /// - Parameter next: The page that takes focus.
    public func focus(_ next: AnyObject) {
        guard page !== next else { return }
        blurPage()
        page = next
        granting = true
        defer { granting = false }
        setFocus(next, true)
    }

    /// `window` (the cmux window) took the keys back while a page has focus, and no click put them
    /// there: the page's window lost them (a new tab's page moved from its provisional pane to its
    /// real one, which presents its window again). The page loses focus with no key change, so the
    /// next ``focus(_:)`` of it grants it again; until now that call found it focused and did nothing,
    /// and typing went to the cmux window.
    ///
    /// Nothing happens inside a grant (AppKit's key changes there are the grant's own), when
    /// `window` is not key (an inactive app has no key window), or during a click (the click
    /// decides where the keys go). A page that cannot take the keys now (``canTakeKeys``) keeps
    /// focus and its ask (``keepAsk``), with no blur and no grant.
    ///
    /// - Parameters:
    ///   - window: The cmux window.
    ///   - event: The event being handled (AppKit's current event in the app).
    /// - Returns: Whether a page lost focus; the caller then re-applies its target.
    public func keysReturned(to window: NSWindow, during event: NSEvent? = NSApplication.shared.currentEvent) -> Bool {
        let clicks: [NSEvent.EventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        guard !granting, let page, keys.isKey(window), !clicks.contains(where: { $0 == event?.type }) else { return false }
        // The page's window was ordered out (its host hidden or empty): a grant now would order it in and take the keys
        // again, and the next layout pass would order it out again (31 key changes per Cmd-N, INSTANT OWNER #36474).
        // It keeps focus and its ask; it is granted once it can take the keys.
        guard canTakeKeys(page) else {
            keepAsk(page)
            return false
        }
        blurPage()
        return true
    }

    /// The page this window gave focus to becomes `next` with no blur and no key change (the keyboard moved to DevTools, a
    /// click chose a page). The old page drops a kept ask, so it cannot take the keys later.
    public func replace(with next: AnyObject?) {
        if let old = page, old !== next { dropAsk(old) }
        page = next
    }

    /// The focused page loses focus. The key window does not change.
    public func blurPage() {
        guard let old = page else { return }
        page = nil
        setFocus(old, false)
    }

    /// Whether the cmux window becomes main when a window it owns (a Chromium page window, a panel) becomes key: AppKit
    /// does not hand main to a child's parent. An owned window that may be main (a sheet) settles main itself.
    ///
    /// - Parameters:
    ///   - ownedCanBecomeMain: The owned window may become main.
    ///   - ownerIsMain: The cmux window is main already.
    ///   - ownerCanBecomeMain: The cmux window may become main.
    /// - Returns: Whether the cmux window makes itself main.
    public nonisolated static func ownerTakesMain(ownedCanBecomeMain: Bool, ownerIsMain: Bool, ownerCanBecomeMain: Bool) -> Bool {
        !ownedCanBecomeMain && !ownerIsMain && ownerCanBecomeMain
    }

    /// `window` takes the keys back from another key window that `shouldReclaim` accepts.
    ///
    /// No change when `window` is key already, no window is key (an inactive app), or inside the grant
    /// of a page that still has focus: its page window took the keys from that grant (AppKit's
    /// didBecomeKey), and taking them back would leave the page focused with no keys. Once the page
    /// blurred (focus moved on inside the grant), the keys come back.
    ///
    /// - Parameters:
    ///   - window: The cmux window.
    ///   - shouldReclaim: Whether `window` takes the keys from this key window.
    public func reclaim(into window: NSWindow, when shouldReclaim: (NSWindow) -> Bool) {
        guard !(granting && page != nil), !keys.isKey(window), let key = keys.keyWindow, key !== window, shouldReclaim(key) else { return }
        keys.makeKey(window)
    }
}
