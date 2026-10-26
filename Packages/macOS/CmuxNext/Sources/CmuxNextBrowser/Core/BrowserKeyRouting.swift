public import AppKit
public import Foundation

/// What the host did with a key equivalent.
public nonisolated enum BrowserKeyDisposition: Hashable, Sendable {
    /// Let the page (and then the engine's default handling) see it.
    case passToPage
    /// The host consumed it (app shortcut such as new tab, palette).
    case handledByHost
}

/// What the host's key dispatcher did with a key-down in `sendEvent`, before the engine's pre-key
/// hook got it (by identity, or as the engine's copy of that key).
public nonisolated enum BrowserDecidedKey: Hashable, Sendable {
    /// The dispatcher never saw it (a synthetic key): the hook runs the dispatcher.
    case undecided
    /// The dispatcher decided it and looked up the focused tab's extension shortcuts (or the page
    /// owns every key): the page gets it.
    case settled
    /// The dispatcher decided it without looking up extension shortcuts (it offered the key to the
    /// page, a code editor sequence or a chord passed it on, or a cmux page in Chromium has the
    /// keyboard): the hook looks up the tab's profile shortcuts, then the page gets it.
    case extensionShortcutOwed
}

/// Hook that runs before the page sees a key equivalent, so app shortcuts
/// win over page handlers. CEF implements it from its pre-key-event handler.
public protocol BrowserKeyRouting: AnyObject {
    /// What the dispatcher decided for `event`. O(1): the engine's pre-key hook asks it first, so a
    /// decided key never runs the dispatcher again.
    func decidedKey(_ event: NSEvent) -> BrowserDecidedKey
    func browserTab(_ tab: any BrowserTab, keyEquivalent event: NSEvent) -> BrowserKeyDisposition
    /// Browser focus mode: the page gets every key, extension shortcuts included.
    func pageOwnsAllKeys(_ tab: any BrowserTab) -> Bool
    /// Before `tab`'s DevTools sees a key equivalent (its own shortcuts,
    /// such as Cmd-Opt-I closing it, win over the DevTools frontend).
    func browserTab(_ tab: any BrowserTab, devToolsKeyEquivalent event: NSEvent) -> BrowserKeyDisposition
    /// After `tab`'s page left a key-down unhandled (no `preventDefault`): returns whether the host
    /// ran the shortcut it held back for the page, so the engine's own handling stops.
    func browserTab(_ tab: any BrowserTab, unhandledKeyEquivalent event: NSEvent) -> Bool
}

extension BrowserKeyRouting {
    public func pageOwnsAllKeys(_ tab: any BrowserTab) -> Bool { false }
    public func browserTab(_ tab: any BrowserTab, devToolsKeyEquivalent event: NSEvent) -> BrowserKeyDisposition { .passToPage }
    public func browserTab(_ tab: any BrowserTab, unhandledKeyEquivalent event: NSEvent) -> Bool { false }
}

// MARK: - Prompts
