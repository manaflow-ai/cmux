public import AppKit

extension NSMenu {
    /// This menu as cmux built it: AppKit adds no rows of its own when it opens as a right-click menu.
    ///
    /// AppKit treats every menu a view hands it for a right-click (`menu(for:)`, `NSView.menu`,
    /// `popUpContextMenu`) as a text context menu: it appends Services and Writing Tools, and on macOS 27
    /// it puts an "Ask Siri" field on top. Read from AppKit 27
    /// (`-[NSMenu _validateAssistantFieldPresenceBeforePresentingMenu]`): the field shows when
    /// `allowsContextMenuPlugIns` is on and a row is titled exactly the localized "Copy" (our Copy folder in
    /// the tab and workspace menus), or when an AppIntents provider owns the clicked view (cmux has none).
    /// Leo 2026-11-22: "there is now an ask siri. which is weird. in the tab." Off here: plugins (Services
    /// and that trigger) and Writing Tools. A text view's own system menu keeps them; only menus cmux
    /// builds call this.
    @discardableResult
    public func withoutSystemItems() -> NSMenu {
        allowsContextMenuPlugIns = false
        if #available(macOS 15.2, *) { automaticallyInsertsWritingToolsItems = false }
        return self
    }

    /// Whether AppKit may add rows of its own to this menu (`withoutSystemItems()` not applied).
    public var allowsSystemItems: Bool {
        if allowsContextMenuPlugIns { return true }
        if #available(macOS 15.2, *) { return automaticallyInsertsWritingToolsItems }
        return false
    }

    /// `menu` with ``withoutSystemItems()``: what every view's `menu(for:)` returns, so a right-click menu
    /// cmux builds never gets AppKit's rows (the "Ask Siri" field, Services, Writing Tools).
    public static func withoutSystemItems(_ menu: NSMenu?) -> NSMenu? { menu?.withoutSystemItems() }
}
