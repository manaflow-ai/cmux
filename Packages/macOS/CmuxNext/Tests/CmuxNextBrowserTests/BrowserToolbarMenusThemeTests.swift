import AppKit
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
import Foundation
import Testing

/// The browser toolbar's own menus (Reload, Back and Forward history, Emulate Device) take the
/// cmux NEXT menu look the right-click menus have (#22787, #22944): every row is a cmux-drawn
/// `ThemedMenuRowView` with an icon, never a plain AppKit row in the system blue, and choosing a
/// row still runs it once (a themed row runs after the menu closes).
@MainActor @Suite(.serialized) struct BrowserToolbarMenusThemeTests {
    /// Every row of `menu` and its submenus: a themed row with an image, or a view the menu keeps
    /// on purpose (the device search field). Separators and section headers stay AppKit's.
    static func expectThemedWithIcons(_ menu: NSMenu, _ name: String) {
        for item in menu.items where !item.isSeparatorItem && !item.isSectionHeader && !item.isHidden {
            if item.view is ThemedMenuRowView {
                #expect(item.image != nil, "\(name): \(item.title) has no icon")
            } else {
                #expect(item.view?.subviews.first is NSSearchField, "\(name): \(item.title) is not themed")
            }
            if let submenu = item.submenu { expectThemedWithIcons(submenu, "\(name) ▸ \(item.title)") }
        }
    }

    static func chrome(back: Int = 0) -> (BrowserChromeView, MockBrowserTab) {
        let tab = MockBrowserEngine().makeMockTab(BrowserTabConfiguration(initialURL: nil))
        let entries = (0...back).map { BrowserNavigationEntry(url: URL(string: "https://example.com/\($0)"), title: "Page \($0)") }
        tab.navigation = BrowserNavigationList(entries: entries, current: back)
        return (BrowserChromeView(tab: tab), tab)
    }

    static func drainRunLoop(until done: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: 0.5)
        while !done(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
    }

    @Test func reloadMenuRowsAreThemedAndRun() throws {
        let (chrome, tab) = Self.chrome()
        let menu = try #require(chrome.reloadButton.menuProvider?())
        #expect(menu.items.map(\.title) == [Strings.menuReload])
        Self.expectThemedWithIcons(menu, "Reload")
        menu.performActionForItem(at: 0)
        #expect(tab.commands.filter { $0 == .reload }.count == 1)
    }

    @Test func hardReloadRowRunsItsOwnAction() {
        var runs: [String] = []
        let menu = BrowserReloadMenu.make(reload: { runs.append("reload") }, hardReload: { runs.append("hard") }, in: .app)
        #expect(menu.items.map(\.title) == [Strings.menuReload, Strings.menuHardReload])
        Self.expectThemedWithIcons(menu, "Reload (WebKit)")
        menu.performActionForItem(at: 1)
        #expect(runs == ["hard"])
    }

    /// A click on a themed row runs it once the menu's tracking has ended, as `popUp` returns.
    @Test func aClickedReloadRowRunsAfterTheMenuCloses() throws {
        let (chrome, tab) = Self.chrome()
        let menu = try #require(chrome.reloadButton.menuProvider?())
        let row = try #require(menu.items[0].view as? ThemedMenuRowView)
        let point = NSPoint(x: 30, y: row.bounds.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            type == .leftMouseDown ? row.mouseDown(with: event) : row.mouseUp(with: event)
        }
        Self.drainRunLoop { tab.commands.contains(.reload) }
        #expect(tab.commands.filter { $0 == .reload }.count == 1)
    }

    @Test func backMenuRowsAreThemedAndGoToTheirEntry() throws {
        let (chrome, tab) = Self.chrome(back: 3)
        let menu = try #require(chrome.backButton.menuProvider?())
        #expect(menu.items.map(\.title) == ["Page 2", "Page 1", "Page 0"])
        Self.expectThemedWithIcons(menu, "Back")
        menu.performActionForItem(at: 1)
        #expect(tab.commands.contains(.goToEntry(-2)))
    }

    static func devices() throws -> [BrowserDeviceMenu.Device] {
        let rows: [[String: Any]] = [
            BrowserDeviceMenuTests.row("iPhone 17", group: "phone", brand: "Apple", released: "2025-09"),
            BrowserDeviceMenuTests.row("Pixel 10", group: "phone", brand: "Google", released: "2025-08"),
            BrowserDeviceMenuTests.row("iPad (10th gen)", group: "tablet", brand: "Apple", released: "2022-10"),
            BrowserDeviceMenuTests.row("MacBook Air 13\"", group: "laptop", brand: "Apple", released: "2022-07"),
            BrowserDeviceMenuTests.row("Studio Display", group: "desktop", brand: "Apple", released: "2022-03"),
            BrowserDeviceMenuTests.row("Kiosk", group: "tablet", brand: "", released: "", origin: "custom"),
        ]
        return BrowserDeviceMenu.devices(list: try JSONSerialization.data(withJSONObject: ["devices": rows]))
    }

    /// The toolbar presents the device menu themed; a search's results, added while it is open, are too.
    @Test func deviceMenuRowsAreThemedWithDeviceIconsAndRun() throws {
        var chosen: [String?] = []
        let current = BrowserDeviceMenu.Current(title: "Galaxy Z Fold 7", orientation: "vertical",
                                                orientations: ["vertical", "horizontal", "vertical-spanned"])
        let menu = BrowserDeviceMenu(devices: try Self.devices(), current: current, fit: nil, fits: ["16:9", "1280"]) { title, _ in
            chosen.append(title)
        }.menu()
        let buttons = BrowserToolbarButtonsView()
        buttons.popUpMenu = { _, _, _ in }
        buttons.present(menu, from: .overflow, themed: true)
        Self.expectThemedWithIcons(menu, "Devices")
        #expect(BrowserDeviceMenu.symbol(group: "tablet") != BrowserDeviceMenu.symbol(group: "phone"), "a tablet and a phone have their own glyphs")

        let all = try #require(menu.items.first { $0.title == BrowserDeviceMenu.Strings.allDevices }?.submenu)
        BrowserDeviceMenu.search("pixel", in: all)
        Self.expectThemedWithIcons(all, "All Devices (search)")
        let result = try #require(all.items.firstIndex { !$0.isHidden && $0.title == "Pixel 10" })
        all.performActionForItem(at: result)
        #expect(chosen == ["Pixel 10"])
    }

    /// A search that hides the checked device drops the menu's state column; clearing the field
    /// while the menu is open shows the checked device again and brings the column back to every
    /// row, not only to the checked one (Codex on #24036: the columns are measured once per theming).
    @Test func clearingTheDeviceSearchBringsTheStateColumnBack() throws {
        let current = BrowserDeviceMenu.Current(title: "iPad (10th gen)", orientation: "vertical", orientations: ["vertical"])
        let menu = BrowserDeviceMenu(devices: try Self.devices(), current: current) { _, _ in }.menu()
        let buttons = BrowserToolbarButtonsView()
        buttons.popUpMenu = { _, _, _ in }
        buttons.present(menu, from: .overflow, themed: true)
        let all = try #require(menu.items.first { $0.title == BrowserDeviceMenu.Strings.allDevices }?.submenu)
        let laptop = try #require(all.items.first { $0.title == "MacBook Air 13\"" }?.view as? ThemedMenuRowView)
        #expect(laptop.columns.state, "the checked iPad gives All Devices a state column")

        BrowserDeviceMenu.search("zzz", in: all)
        #expect(all.items.contains { $0.title == "iPad (10th gen)" && $0.isHidden })
        #expect(!laptop.columns.state, "the hidden checked iPad leaves no column")

        BrowserDeviceMenu.search("", in: all)
        #expect(all.items.contains { $0.title == "iPad (10th gen)" && !$0.isHidden })
        #expect(laptop.columns.state, "the checked iPad shows again, and so does the column")
        let menuItem = try #require(laptop.menuItem)
        #expect(ThemedMenuRowView.leading(of: menuItem, in: laptop.columns) == ThemedMenuRowView.stateTitleX)
    }
}
