public import AppKit

/// A focused terminal surface's copy mode: the key router's `terminalCopyMode` fact, read on every key from
/// the surface its cached facts found (p04-input-053).
@MainActor
public protocol KeyFactsCopyModeSource: AnyObject {
    var isCopyModeActive: Bool { get }
}

/// A focused address bar's suggestion list: the key router's `omnibarListOpen` fact, read on every key from
/// the bar its cached facts found (p04-input-053).
@MainActor
public protocol KeyFactsSuggestionSource: AnyObject {
    var isShowingSuggestions: Bool { get }
}

/// A focused Chromium tab: whether `window` is its page window now, so the key reaches the page and
/// Chromium reports what the page leaves unhandled (the key router's `pageReportsUnhandledKeys` fact). The
/// page window is placed, moved or hidden with no focus change, so the router asks on every key (p04-input-053).
@MainActor
public protocol KeyFactsPageWindowSource: AnyObject {
    func isPageWindow(_ window: NSWindow) -> Bool
}
