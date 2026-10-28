import AppKit
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
import Foundation
import Testing

/// The browser toolbar's own menus (Reload, Back and Forward history, Emulate Device) are standard
/// macOS menus like the right-click menus (Lawrence 2026-10-23): every row is a plain AppKit row
/// with an icon, and choosing a row still runs it once.
@MainActor @Suite(.serialized) struct BrowserToolbarMenusThemeTests {
    /// Every row of `menu` and its submenus: a native row with an image, or a view the menu keeps
    /// on purpose (the device search field). Separators and section headers stay AppKit's.
    static func expectThemedWithIcons(_ menu: NSMenu, _ name: String) {
        for item in menu.items where !item.isSeparatorItem && !item.isSectionHeader && !item.isHidden {
            if let view = item.view {
                #expect(view.subviews.first is NSSearchField, "\(name): \(item.title) is custom-drawn, not a standard macOS row")
            } else {
                #expect(item.image != nil, "\(name): \(item.title) has no icon")
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

    @Test func reloadMenuRowsAreNativeAndRun() throws {
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

    @Test func backMenuRowsAreNativeAndGoToTheirEntry() throws {
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

    /// The toolbar presents the device menu native; a search's results, added while it is open, are too.
    @Test func deviceMenuRowsAreNativeWithDeviceIconsAndRun() throws {
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

    /// A search that hides the checked device and then clears shows it again, still checked: AppKit
    /// draws the state column itself.
    @Test func clearingTheDeviceSearchShowsTheCheckedDeviceAgain() throws {
        let current = BrowserDeviceMenu.Current(title: "iPad (10th gen)", orientation: "vertical", orientations: ["vertical"])
        let menu = BrowserDeviceMenu(devices: try Self.devices(), current: current) { _, _ in }.menu()
        let buttons = BrowserToolbarButtonsView()
        buttons.popUpMenu = { _, _, _ in }
        buttons.present(menu, from: .overflow, themed: true)
        let all = try #require(menu.items.first { $0.title == BrowserDeviceMenu.Strings.allDevices }?.submenu)
        BrowserDeviceMenu.search("zzz", in: all)
        #expect(all.items.contains { $0.title == "iPad (10th gen)" && $0.isHidden })
        BrowserDeviceMenu.search("", in: all)
        let iPad = try #require(all.items.first { $0.title == "iPad (10th gen)" })
        #expect(!iPad.isHidden && iPad.state == .on && iPad.view == nil)
        Self.expectThemedWithIcons(all, "All Devices (cleared)")
    }
}
