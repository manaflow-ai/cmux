import AppKit
@testable import CmuxNextActions
import Testing

/// The browser More (⋮) menu reads like ChatGPT Atlas's (Lawrence, 2026-11-23: "we need better menu design.
/// potentially let's just match these screenshots"): short sections of plain rows, no icon column, the rarely
/// used rows and the hidden toolbar buttons in Tools, Settings last.
@MainActor
struct BrowserMoreMenuLayoutTests {
    private static let bound: [ActionID] = [
        "find", "browserPrint", "browserZoomOut", "browserZoomIn", "browserZoomReset", "browserDevice",
        "browserScreenshotPage", "browserScreenshotSection", "bookmark.manager", "browserShowHistory",
        "browser.downloads.show", "passwords.open", "browser.extensions.manage", "importFromBrowser", "history.clear",
        "splitBrowserRight", "toggleBrowserFocusMode", "palette.browserOpenDefault", "browser.openInWebKit",
        "tabGroup.create", "tabGroup.addTab", "openSettings", "browser.profile.choose",
    ]

    private static func menu(buttons: [ContextMenuEntry] = [], toolsFooter: [NSMenuItem] = []) -> NSMenu {
        let registry = ActionRegistry.standard()
        for id in bound { registry.bind(id) {} }
        return registry.makeBrowserMoreMenu(tabKey: "tab-1", buttons: buttons, chromium: true, toolsFooter: toolsFooter) { _ in
            NSMenuItem(title: "Zoom", action: nil, keyEquivalent: "")
        }
    }

    /// Top level, section by section ("|" a separator), as Atlas lays its menu out.
    private static func outline(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "|" : $0.title }
    }

    @Test func theTopLevelIsShortSectionsOfPlainRows() {
        let menu = Self.menu()
        #expect(Self.outline(menu) == [
            "Find in Page", "Print…", "|",
            "Zoom", "|",
            "Emulate Device…", "Take Screenshot", "|",
            "Import from Browser…", "Passwords", "Downloads", "History", "Clear History…", "|",
            "Tools", "|",
            "Settings…",
        ])
        // Plain rows, as Atlas draws them: no icon column at the top level.
        #expect(menu.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.image == nil })
        // Take Screenshot is the drag-a-section capture; the whole page is a Tools row.
        let shot = menu.items.first { $0.title == "Take Screenshot" }
        #expect(shot.flatMap(ActionRegistry.menuRun(of:))?.id == "browserScreenshotSection")
    }

    @Test func rarelyUsedRowsAndHiddenButtonsLiveInTools() throws {
        let footer = NSMenuItem(title: "Show in Toolbar", action: nil, keyEquivalent: "")
        let menu = Self.menu(buttons: [.action("browser.profile.choose")], toolsFooter: [footer])
        let top = Self.outline(menu)
        #expect(!top.contains("Choose Browser Profile…"), "a hidden toolbar button is a top-level row")
        #expect(!top.contains("Show in Toolbar"))
        let tools = try #require(menu.items.first { $0.title == "Tools" }?.submenu)
        let titles = tools.items.map(\.title)
        for title in ["Choose Browser Profile…", "Screenshot Page", "Bookmark Manager", "Show in Toolbar"] {
            #expect(titles.contains(title), "Tools has no \(title)")
        }
        #expect(tools.items.last === footer, "Show in Toolbar is not Tools' last row")
    }
}
