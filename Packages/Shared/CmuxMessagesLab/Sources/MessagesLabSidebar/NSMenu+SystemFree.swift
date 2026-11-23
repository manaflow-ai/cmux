import AppKit

extension NSMenu {
    /// `menu` with none of AppKit's own rows on a right-click: no Services, no Writing Tools, and no
    /// "Ask Siri" field, which macOS 27 puts on top of a context menu that allows plugins and has a row
    /// titled "Copy" (Leo 2026-11-22: "there is now an ask siri. which is weird. in the tab."). The app's
    /// `NSMenu.withoutSystemItems(_:)` (CmuxNextDesign) is the same; this module does not link it.
    static func systemFree(_ menu: NSMenu?) -> NSMenu? {
        guard let menu else { return nil }
        menu.allowsContextMenuPlugIns = false
        if #available(macOS 15.2, *) { menu.automaticallyInsertsWritingToolsItems = false }
        return menu
    }
}
