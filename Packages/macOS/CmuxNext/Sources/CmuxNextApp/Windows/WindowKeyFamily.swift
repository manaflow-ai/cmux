import AppKit

/// R131: when a cmux window stops being key, its shown pages are captured
/// for hover cards in other windows, but only when the keyboard left the
/// window's family: not when a child or descendant window (a Chromium page
/// window, popup, palette, hover card) or an attached sheet took it.
enum WindowKeyFamily {
    /// Whether `newKey` (the key window after the resign, nil when the app
    /// resigned active) is outside `window`'s family. `owner` is a window's
    /// parent or sheet parent.
    static func leftFamily<W: AnyObject>(of window: W, newKey: W?, owner: (W) -> W?) -> Bool {
        var next = newKey
        // Window chains are a few levels deep; the bound guards a cycle.
        for _ in 0..<32 {
            guard let current = next else { return true }
            if current === window { return false }
            next = owner(current)
        }
        return true
    }

    /// Captures `presenters`' shown pages into `cache` when the keyboard
    /// left `window`'s family for `newKey`.
    static func windowResignedKey<W: AnyObject>(_ window: W, newKey: W?, owner: (W) -> W?,
                                                presenters: [any SurfacePresenter], cache: TabContentCache) {
        guard leftFamily(of: window, newKey: newKey, owner: owner) else { return }
        cache.windowDidResignKey(presenters: presenters)
    }
}
