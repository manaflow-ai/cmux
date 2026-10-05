public import AppKit

/// Automated clicks whose native context menu is still expected. WebKit
/// builds a context menu for an automated click that opens one, as for a
/// person's; that menu must never show (``CmuxWebView/willOpenMenu(_:with:)``
/// empties it). A page can cancel the `contextmenu` event, and then no menu
/// comes to use the suppression up, so a person's own click that opens a
/// context menu clears every pending one: their menu always shows.
struct BrowserAutomationContextMenuSuppression: Equatable {
    /// Suppressions not yet used by a menu.
    private(set) var pending: Int

    init(pending: Int = 0) {
        self.pending = max(0, pending)
    }

    /// Whether `event`, a mouse-down, opens a context menu in WebKit.
    static func opensContextMenu(_ event: NSEvent) -> Bool {
        event.type == .rightMouseDown
    }

    /// Browser automation delivered mouse-down `event`.
    mutating func noteAutomatedMouseDown(_ event: NSEvent) {
        if Self.opensContextMenu(event) { pending += 1 }
    }

    /// A person's mouse-down `event` reached the web view.
    mutating func noteUserMouseDown(_ event: NSEvent) {
        if Self.opensContextMenu(event) { pending = 0 }
    }

    /// Uses one pending suppression; `true` when the menu opening now must
    /// not show.
    mutating func consume() -> Bool {
        guard pending > 0 else { return false }
        pending -= 1
        return true
    }

    /// Forgets every pending suppression.
    mutating func cancelAll() {
        pending = 0
    }
}
