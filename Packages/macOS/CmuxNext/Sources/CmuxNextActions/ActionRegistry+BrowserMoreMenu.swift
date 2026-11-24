public import AppKit

extension ActionRegistry {
    /// The browser toolbar's More (⋮) menu for the tab `tabKey`, laid out as ChatGPT Atlas's (Lawrence 2026-11-23:
    /// "we need better menu design. potentially let's just match these screenshots"; the App draws it on cmux's
    /// glass): short sections of plain rows with no icon column. Find in Page and Print; the zoom row `zoomRow` makes
    /// from Zoom Out, Zoom In and Actual Size; Emulate Device and Take Screenshot (a dragged section); the browser's
    /// own data (Import from Browser, Passwords, Downloads, History, Clear History); Tools; Settings.
    ///
    /// Tools holds the rows a page needs less often: `buttons` (the toolbar buttons not shown now), Screenshot Page,
    /// Bookmark Manager, Manage Extensions, the split, focus and engine rows, the tab group rows, then
    /// `toolsFooter` (the App's Show in Toolbar). New Tab, New Window, New Incognito Window, Full Screen and Help are
    /// not in it: the + button, the File, View and Help menus and their shortcuts run them. Rows the tab cannot run
    /// drop out.
    ///
    /// The menu before this one (Lawrence, 2026-11-20, 4da5e915533f) put the hidden toolbar buttons first and every
    /// row at the top level with an icon: 22 rows, the debug Design Mode row at the top.
    ///
    /// - Parameters:
    ///   - tabKey: the tab every row runs on.
    ///   - buttons: the rows of the toolbar buttons the toolbar does not show now; they go in Tools.
    ///   - chromium: the tab's page is Chromium's (Tools offers Open in WebKit, else Open in Chromium).
    ///   - toolsFooter: rows Tools ends with, after a separator (the App's Show in Toolbar).
    ///   - zoomRow: makes the zoom row from its three items (only when all three can show); nil leaves it out.
    public func makeBrowserMoreMenu(tabKey: String, buttons: [ContextMenuEntry], chromium: Bool, toolsFooter: [NSMenuItem] = [],
                                    zoomRow: ([NSMenuItem]) -> NSMenuItem?) -> NSMenu {
        let target = ActionTargetRef(kind: .tab, id: tabKey)
        let rows = { (entries: [ContextMenuEntry]) in self.contextMenuItems(for: .browserPage, target: target, entries: entries) }
        let zoom = rows([.action("browserZoomOut"), .action("browserZoomIn"), .action("browserZoomReset")])
        let tools = toolsMenu(rows: rows, buttons: buttons, chromium: chromium, footer: toolsFooter)
        let sections: [[NSMenuItem]] = [
            Self.retitled(rows([.action("find"), .action("browserPrint")]), ["find": BrowserMoreMenuStrings.findInPage]),
            (zoom.count == 3 ? zoomRow(zoom) : nil).map { [$0] } ?? [],
            Self.retitled(rows([.action("browserDevice"), .action("browserScreenshotSection")]),
                          ["browserScreenshotSection": BrowserMoreMenuStrings.takeScreenshot]),
            Self.retitled(rows([.action("importFromBrowser"), .action("passwords.open"), .action("browser.downloads.show"),
                                .action("browserShowHistory"), .action("history.clear")]),
                          ["browser.downloads.show": BrowserMoreMenuStrings.downloads, "browserShowHistory": BrowserMoreMenuStrings.history]),
            tools.map { [$0] } ?? [],
            rows([.action("openSettings")]),
        ]
        let menu = NSMenu()
        for section in sections where !section.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            section.forEach(menu.addItem)
        }
        Self.dropIcons(menu)
        return menu
    }

    /// Tools: the hidden toolbar buttons, then the rows a page needs less often, then `footer`. Nil when it has no row.
    private func toolsMenu(rows: ([ContextMenuEntry]) -> [NSMenuItem], buttons: [ContextMenuEntry], chromium: Bool,
                           footer: [NSMenuItem]) -> NSMenuItem? {
        let sections: [[NSMenuItem]] = [
            rows(buttons),
            rows([.action("browserScreenshotPage"), .action("bookmark.manager"), .action("browser.extensions.manage")]),
            rows([.action("splitBrowserRight"), .action("toggleBrowserFocusMode"), .action("palette.browserOpenDefault"),
                  .action(chromium ? "browser.openInWebKit" : "browser.openInChromium")]),
            rows([.action("tabGroup.create"), .action("tabGroup.addTab")]),
            footer,
        ]
        guard sections.contains(where: { !$0.isEmpty }) else { return nil }
        let title = MenuFolder.tools.title
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = true
        for section in sections where !section.isEmpty {
            if !submenu.items.isEmpty { submenu.addItem(.separator()) }
            section.forEach(submenu.addItem)
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("cmux.browser.more.tools")
        item.submenu = submenu
        return item
    }

    /// `items` with the menu-only titles `titles` gives by the action each runs (Find… reads Find in Page here).
    private static func retitled(_ items: [NSMenuItem], _ titles: [ActionID: String]) -> [NSMenuItem] {
        for item in items {
            let id = menuRun(of: item)?.id ?? (item.representedObject as? String).map { ActionID(rawValue: $0) }
            if let id, let title = titles[id] { item.title = title }
        }
        return items
    }

    /// Atlas's rows are plain text: no icon column in the menu or its submenus. A row's icon is still its
    /// action's in the palette.
    private static func dropIcons(_ menu: NSMenu) {
        for item in menu.items {
            item.image = nil
            if let submenu = item.submenu { dropIcons(submenu) }
        }
    }
}
