public import AppKit

/// A focused terminal surface's copy mode: the key router's `terminalCopyMode` fact, read on every key from
/// the surface its cached facts found.
@MainActor
public protocol KeyFactsCopyModeSource: AnyObject {
    var isCopyModeActive: Bool { get }
}

/// A focused address bar's suggestion list: the key router's `omnibarListOpen` fact, read on every key from
/// the bar its cached facts found.
@MainActor
public protocol KeyFactsSuggestionSource: AnyObject {
    var isShowingSuggestions: Bool { get }
}

/// A focused Chromium tab: whether `window` is its page window now, so the key reaches the page and
/// Chromium reports what the page leaves unhandled (the key router's `pageReportsUnhandledKeys` fact). The
/// page window is placed, moved or hidden with no focus change, so the router asks on every key.
@MainActor
public protocol KeyFactsPageWindowSource: AnyObject {
    func isPageWindow(_ window: NSWindow) -> Bool
    /// Chromium Host: whether the tab's page view is `window`'s first responder and its host reports the
    /// chords the page leaves unhandled, so the page gets page-ownable keys first.
    func hostedPageHasKeys(in window: NSWindow) -> Bool
    /// Chromium Host: whether the tab's page view is `window`'s first responder and its page holds a
    /// keyboard lock in its fullscreen, so the page gets the chords cmux would run.
    func hostedPageLocksKeys(in window: NSWindow) -> Bool
}

extension KeyFactsPageWindowSource {
    /// A page with no Chromium Host page view never has the keys through one.
    public func hostedPageHasKeys(in window: NSWindow) -> Bool { false }
    /// A page with no Chromium Host page view never locks the keys.
    public func hostedPageLocksKeys(in window: NSWindow) -> Bool { false }
}
