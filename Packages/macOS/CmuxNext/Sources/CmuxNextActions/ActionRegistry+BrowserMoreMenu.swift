public import AppKit

extension ActionRegistry {
    /// The browser toolbar's More (⋮) menu for the tab `tabKey`, cut to what a page needs (Lawrence 2026-11-20:
    /// "let's stop using native macos for that and make it super good"; the App draws it on cmux's glass):
    /// `buttons` first (the toolbar buttons not shown, as rows), then Find and Print; the zoom row `zoomRow` makes
    /// from Zoom Out, Zoom In and Actual Size; Emulate Device and the screenshots; the browser's own pages and data;
    /// More Tools; Settings. New Tab, New Window, New Incognito Window, Full Screen and Help are not in it: the +
    /// button, the File, View and Help menus and their shortcuts run them. Rows the tab cannot run drop out.
    ///
    /// - Parameters:
    ///   - tabKey: the tab every row runs on.
    ///   - buttons: the rows of the toolbar buttons the toolbar does not show now.
    ///   - chromium: the tab's page is Chromium's (More Tools offers Open in WebKit, else Open in Chromium).
    ///   - zoomRow: makes the zoom row from its three items (only when all three can show); nil leaves it out.
    public func makeBrowserMoreMenu(tabKey: String, buttons: [ContextMenuEntry], chromium: Bool,
                                    zoomRow: ([NSMenuItem]) -> NSMenuItem?) -> NSMenu {
        let target = ActionTargetRef(kind: .tab, id: tabKey)
        let rows = { (entries: [ContextMenuEntry]) in self.contextMenuItems(for: .browserPage, target: target, entries: entries) }
        let zoom = rows([.action("browserZoomOut"), .action("browserZoomIn"), .action("browserZoomReset")])
        let sections: [[NSMenuItem]] = [
            rows(buttons), rows([.action("find"), .action("browserPrint")]), (zoom.count == 3 ? zoomRow(zoom) : nil).map { [$0] } ?? [],
            rows([.action("browserDevice"), .action("browserScreenshotPage"), .action("browserScreenshotSection")]),
            rows([.action("bookmark.manager"), .action("browserShowHistory"), .action("browser.downloads.show"), .action("passwords.open"),
                  .action("browser.extensions.manage"), .action("importFromBrowser"), .action("history.clear")]),
            rows([.folder(.tools, [
                .action("splitBrowserRight"), .action("toggleBrowserFocusMode"), .action("palette.browserOpenDefault"),
                .action(chromium ? "browser.openInWebKit" : "browser.openInChromium"), .action("tabGroup.create"), .action("tabGroup.addTab"),
            ])]),
            rows([.action("openSettings")]),
        ]
        let menu = NSMenu()
        for section in sections where !section.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            section.forEach(menu.addItem)
        }
        return menu
    }
}
