import AppKit
@testable import CmuxNextBrowser
import Testing

/// The Emulate Device menu built from `browser.devices.list` (u2406): sections by the daemon's
/// `group` (Phones, Foldables, Tablets, Laptops, Desktops & Displays, Smart Displays), newest
/// device first, All Devices with phones split by brand, rumored devices only under All
/// Devices, and a search field that narrows All Devices to the matching rows.
@MainActor @Suite(.serialized) struct BrowserDeviceMenuTests {
    static func row(_ title: String, group: String, brand: String, released: String, shown: Bool = true,
                    rumored: Bool = false, origin: String = "cmux") -> [String: Any] {
        ["title": title, "group": group, "brand": brand, "released": released, "show-by-default": shown,
         "rumored": rumored, "origin": origin, "category": "mobile",
         "screen": ["vertical": ["width": 390, "height": 844], "horizontal": ["width": 844, "height": 390], "device-pixel-ratio": 3]]
    }

    static let list: [[String: Any]] = [
        row("iPhone 12", group: "phone", brand: "Apple", released: "2020-10"),
        row("iPhone 17", group: "phone", brand: "Apple", released: "2025-09"),
        row("iPhone 18", group: "phone", brand: "Apple", released: "2027-03", shown: false, rumored: true),
        row("Pixel 6", group: "phone", brand: "Google", released: "2021-10", shown: false),
        row("Pixel 10", group: "phone", brand: "Google", released: "2025-08"),
        row("Galaxy Z Fold 7", group: "foldable", brand: "Samsung", released: "2025-07"),
        row("iPad (10th gen)", group: "tablet", brand: "Apple", released: "2022-10"),
        row("MacBook Air 13\"", group: "laptop", brand: "Apple", released: "2022-07"),
        row("Studio Display", group: "desktop", brand: "Apple", released: "2022-03"),
        row("Nest Hub", group: "smart-display", brand: "Google", released: "2018-10", shown: false),
        row("Kiosk", group: "tablet", brand: "", released: "", origin: "custom"),
    ]

    static func menu() -> NSMenu {
        let data = try! JSONSerialization.data(withJSONObject: ["devices": list])
        return BrowserDeviceMenu(devices: BrowserDeviceMenu.devices(list: data), current: nil) { _, _ in }.menu()
    }

    static func titles(_ menu: NSMenu) -> [String] {
        menu.items.filter { !$0.isSeparatorItem && !$0.isHidden && $0.view == nil }.map(\.title)
    }

    static func allDevices(_ menu: NSMenu) -> NSMenu {
        menu.items.first { $0.title == BrowserDeviceMenu.Strings.allDevices }!.submenu!
    }

    @Test func theTopLevelGroupsShownDevicesNewestFirst() {
        let strings = BrowserDeviceMenu.Strings.self
        #expect(Self.titles(Self.menu()) == [
            strings.noDevice,
            strings.group("phone"), "iPhone 17", "Pixel 10", "iPhone 12",
            strings.group("foldable"), "Galaxy Z Fold 7",
            strings.group("tablet"), "iPad (10th gen)",
            strings.group("laptop"), "MacBook Air 13\"",
            strings.group("desktop"), "Studio Display",
            strings.custom, "Kiosk",
            strings.allDevices,
        ])
    }

    @Test func allDevicesSplitsPhonesByBrandAndListsEveryDevice() throws {
        let all = Self.allDevices(Self.menu())
        #expect(all.items.first?.view?.subviews.first is NSSearchField)
        let strings = BrowserDeviceMenu.Strings.self
        #expect(Self.titles(all) == [
            strings.group("phone"), "Apple", "Google",
            strings.group("foldable"), "Galaxy Z Fold 7",
            strings.group("tablet"), "iPad (10th gen)",
            strings.group("laptop"), "MacBook Air 13\"",
            strings.group("desktop"), "Studio Display",
            strings.group("smart-display"), "Nest Hub",
        ])
        let apple = try #require(all.items.first { $0.title == "Apple" }?.submenu)
        #expect(Self.titles(apple) == ["iPhone 17", "iPhone 12", strings.rumored("iPhone 18")])
        let google = try #require(all.items.first { $0.title == "Google" }?.submenu)
        #expect(Self.titles(google) == ["Pixel 10", "Pixel 6"])
    }

    @Test func searchNarrowsAllDevicesToMatchingRows() {
        let all = Self.allDevices(Self.menu())
        BrowserDeviceMenu.search("pixel", in: all)
        #expect(Self.titles(all) == ["Pixel 10", "Pixel 6"])
        BrowserDeviceMenu.search("13", in: all)
        #expect(Self.titles(all) == ["MacBook Air 13\""])
        BrowserDeviceMenu.search("", in: all)
        #expect(Self.titles(all).contains("Apple"))
        #expect(!Self.titles(all).contains("Pixel 10"))
    }

    @Test func choosingARumoredRowSendsItsRealTitle() throws {
        var chosen: String?
        let data = try JSONSerialization.data(withJSONObject: ["devices": Self.list])
        let menu = BrowserDeviceMenu(devices: BrowserDeviceMenu.devices(list: data), current: nil) { title, _ in chosen = title }.menu()
        let apple = try #require(Self.allDevices(menu).items.first { $0.title == "Apple" }?.submenu)
        let item = try #require(apple.items.first { $0.title == BrowserDeviceMenu.Strings.rumored("iPhone 18") })
        _ = (item.target as? NSObject)?.perform(item.action)
        #expect(chosen == "iPhone 18")
    }
}
