public import AppKit
import CmuxNextDesign

/// Chrome's device menu (Emulate Device…) drawn from the daemon's device
/// list (`browser.devices.list`, browser-devices-v1, cx-ocbf3): No Device,
/// the fits, the current device's orientations, the default-visible devices
/// by the daemon's `group` (Phones, Foldables, Tablets, Laptops, Desktops &
/// Displays, Smart Displays) newest first, the custom devices, and every
/// device under All Devices (phones split by brand, rumored devices last,
/// a search field on top). It holds no device data; each row sends `choose`.
/// Every row has an icon (its device class, the fit's or the orientation's),
/// shown as a standard macOS menu in the toolbar's look (`NSMenu.themeRows(in:)`).
@MainActor
public struct BrowserDeviceMenu {
    /// One device of the daemon's list, as the menu shows it.
    public struct Device: Sendable {
        public var title: String
        /// The daemon's `category`: Chrome's sections (mobile, foldable, tablet-desktop or smart-display).
        public var category: String
        /// The daemon's `group`: phone, foldable, tablet, laptop, desktop or smart-display.
        public var group: String
        /// The maker the All Devices menu files a phone under ("Other" when the list names none).
        public var brand: String
        /// The release month ("2025-09"); empty for generic screens, which sort last.
        public var released: String
        /// An unannounced device: only under All Devices, marked as rumored.
        public var rumored: Bool
        public var shownByDefault: Bool
        public var isCustom: Bool
        /// "W × H, device pixel ratio R" (the device's portrait screen), if the list has it.
        public var size: (width: Int, height: Int, ratio: Double)?

        public init(title: String, category: String, group: String? = nil, brand: String = "Other", released: String = "",
                    rumored: Bool = false, shownByDefault: Bool, isCustom: Bool, size: (width: Int, height: Int, ratio: Double)?) {
            self.title = title
            self.category = category
            self.group = group ?? Self.group(category: category)
            self.brand = brand.isEmpty ? "Other" : brand
            self.released = released
            self.rumored = rumored
            self.shownByDefault = shownByDefault
            self.isCustom = isCustom
            self.size = size
        }

        /// The group of an older daemon's list, which names only Chrome's category.
        static func group(category: String) -> String {
            switch category {
            case "foldable", "smart-display": category
            case "tablet-desktop": "tablet"
            default: "phone"
            }
        }

        /// The menu row's text: the title, marked when the device is rumored.
        var rowTitle: String { rumored ? Strings.rumored(title) : title }
    }

    /// The tab's emulation as the daemon resolved it.
    public struct Current: Sendable {
        public var title: String
        public var orientation: String
        public var orientations: [String]

        public init(title: String, orientation: String, orientations: [String]) {
            self.title = title
            self.orientation = orientation
            self.orientations = orientations
        }
    }

    public var devices: [Device]
    public var current: Current?
    /// A row's choice: the device title (nil: No Device) and the orientation (nil: the device's first).
    public var choose: @MainActor (String?, String?) -> Void
    /// The tab's fit ("16:9" or "1280", nil for none), the fits the daemon serves (their rows show), and a fit row's action.
    public var fit: String?
    public var fits: [String]
    public var toggleFit: @MainActor (String) -> Void

    public init(devices: [Device], current: Current?, fit: String? = nil, fits: [String] = [],
                toggleFit: @escaping @MainActor (String) -> Void = { _ in }, choose: @escaping @MainActor (String?, String?) -> Void) {
        self.devices = devices
        self.current = current
        self.fit = fit
        self.fits = fits
        self.toggleFit = toggleFit
        self.choose = choose
    }

    /// The daemon's groups, in menu order.
    static let groups = ["phone", "foldable", "tablet", "laptop", "desktop", "smart-display"]
    /// Brands listed first under Phones; the rest follow by name, "Other" last.
    private static let leadingBrands = ["Apple", "Google", "Samsung"]

    /// `list` newest first (a generic screen, without a release month, last), rumored devices after the rest;
    /// the list's order breaks ties.
    static func newestFirst(_ list: [Device]) -> [Device] {
        list.enumerated().sorted { lhs, rhs in
            let (a, b) = (lhs.element, rhs.element)
            if a.rumored != b.rumored { return !a.rumored }
            if a.released != b.released { return a.released > b.released }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    static func brands(_ list: [Device]) -> [String] {
        let names = Set(list.map(\.brand))
        let leading = leadingBrands.filter(names.contains)
        let rest = names.subtracting(leadingBrands).subtracting(["Other"]).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return leading + rest + (names.contains("Other") ? ["Other"] : [])
    }

    /// The device class's glyph: a row's icon in every section and search result.
    static func symbol(group: String) -> String {
        switch group {
        case "foldable": "rectangle.split.2x1"
        case "tablet": "ipad"
        case "laptop": "laptopcomputer"
        case "desktop": "desktopcomputer"
        case "smart-display": "tv"
        default: "iphone"
        }
    }

    static func symbol(orientation: String) -> String {
        switch orientation {
        case "vertical": "rectangle.portrait"
        case "horizontal": "rectangle"
        case "vertical-spanned": "rectangle.split.2x1"
        default: "rectangle.split.1x2"
        }
    }

    public func menu() -> NSMenu {
        let menu = NSMenu()
        add(Strings.noDevice, symbol: "macwindow", to: menu, checked: current == nil && fit == nil) { choose(nil, nil) }
        for (value, title) in [("16:9", Strings.fitDesktop), ("1280", Strings.fitDesktop1280)] where fits.contains(value) {
            add(title, symbol: "rectangle.ratio.16.to.9", to: menu, checked: fit == value) { toggleFit(value) }
        }
        if let current, current.orientations.count > 1 {
            menu.addItem(.separator())
            for name in current.orientations {
                add(Strings.orientation(name), symbol: Self.symbol(orientation: name), to: menu,
                    checked: name == current.orientation) { choose(current.title, name) }
            }
        }
        let builtIn = devices.filter { !$0.isCustom }
        for group in Self.groups {
            let shown = Self.newestFirst(builtIn.filter { $0.group == group && $0.shownByDefault && !$0.rumored })
            guard !shown.isEmpty else { continue }
            menu.addItem(.sectionHeader(title: Strings.group(group)))
            addDevices(shown, to: menu)
        }
        let custom = devices.filter(\.isCustom)
        if !custom.isEmpty {
            menu.addItem(.sectionHeader(title: Strings.custom))
            addDevices(custom, to: menu)
        }
        menu.addItem(.separator())
        let allItem = NSMenuItem(title: Strings.allDevices, action: nil, keyEquivalent: "")
        allItem.image = NSImage.menuSymbol("list.bullet")
        allItem.submenu = allDevices(builtIn)
        menu.addItem(allItem)
        return menu
    }

    /// All Devices: the search field, then every built-in device by group (phones in a submenu per brand).
    private func allDevices(_ builtIn: [Device]) -> NSMenu {
        let all = NSMenu()
        let search = BrowserDeviceSearch(devices: Self.newestFirst(builtIn)) { [self] device, menu in
            addDevices([device], to: menu)
        }
        all.addItem(search.fieldItem())
        for group in Self.groups {
            let listed = Self.newestFirst(builtIn.filter { $0.group == group })
            guard !listed.isEmpty else { continue }
            all.addItem(.sectionHeader(title: Strings.group(group)))
            guard group == "phone" else {
                addDevices(listed, to: all)
                continue
            }
            for brand in Self.brands(listed) {
                let sub = NSMenu()
                addDevices(listed.filter { $0.brand == brand }, to: sub)
                let item = NSMenuItem(title: brand == "Other" ? Strings.otherBrand : brand, action: nil, keyEquivalent: "")
                item.image = NSImage.menuSymbol(Self.symbol(group: group))
                item.submenu = sub
                all.addItem(item)
            }
        }
        return all
    }

    /// Narrows All Devices (`menu`) to the devices whose brand and title hold every word of `query`, newest
    /// first; an empty query shows the whole list again. The search field calls it as you type.
    public static func search(_ query: String, in menu: NSMenu) {
        BrowserDeviceSearch.of(menu)?.apply(query, in: menu)
    }

    private func addDevices(_ list: [Device], to menu: NSMenu) {
        for device in list {
            let tip = device.size.map { Strings.details(width: $0.width, height: $0.height, ratio: $0.ratio) }
            add(device.rowTitle, symbol: Self.symbol(group: device.group), to: menu, checked: device.title == current?.title,
                toolTip: tip) { choose(device.title, nil) }
        }
    }

    private func add(_ title: String, symbol: String, to menu: NSMenu, checked: Bool = false, toolTip: String? = nil,
                     _ action: @escaping @MainActor () -> Void) {
        let target = Row(action)
        let item = NSMenuItem(title: title, action: #selector(Row.run), keyEquivalent: "")
        item.target = target
        item.representedObject = target // the item keeps its target
        item.state = checked ? .on : .off
        item.toolTip = toolTip
        item.image = NSImage.menuSymbol(symbol)
        menu.addItem(item)
    }

    @MainActor private final class Row: NSObject {
        let action: @MainActor () -> Void
        init(_ action: @escaping @MainActor () -> Void) { self.action = action }
        @objc func run() { action() }
    }

    /// The menu's text (BrowserDevices.xcstrings).
    nonisolated enum Strings {
        static var noDevice: String { String(localized: "browserDevices.none", defaultValue: "No Device", table: "BrowserDevices", bundle: .module) }
        static var allDevices: String { String(localized: "browserDevices.all", defaultValue: "All Devices", table: "BrowserDevices", bundle: .module) }
        /// The menu rows of the two fits (the palette actions `browserFitDesktop` and `browserFitDesktop1280` have their own strings).
        static var fitDesktop: String {
            String(localized: "browserDevices.fitDesktop", defaultValue: "Fit as 16:9 Desktop", table: "BrowserDevices", bundle: .module)
        }
        static var fitDesktop1280: String {
            String(localized: "browserDevices.fitDesktop1280", defaultValue: "Fit as Desktop (1280)", table: "BrowserDevices", bundle: .module)
        }
        static var custom: String { String(localized: "browserDevices.custom", defaultValue: "Custom", table: "BrowserDevices", bundle: .module) }

        static func details(width: Int, height: Int, ratio: Double) -> String {
            let ratioText = ratio.formatted(.number.precision(.fractionLength(0...3)))
            return String(localized: "browserDevices.details", defaultValue: "\(width) × \(height), device pixel ratio \(ratioText)",
                          table: "BrowserDevices", bundle: .module)
        }

        /// A section of the menu: the daemon's `group`.
        static func group(_ group: String) -> String {
            switch group {
            case "foldable": String(localized: "browserDevices.category.foldable", defaultValue: "Foldables", table: "BrowserDevices", bundle: .module)
            case "tablet": String(localized: "browserDevices.group.tablet", defaultValue: "Tablets", table: "BrowserDevices", bundle: .module)
            case "laptop": String(localized: "browserDevices.group.laptop", defaultValue: "Laptops", table: "BrowserDevices", bundle: .module)
            case "desktop":
                String(localized: "browserDevices.group.desktop", defaultValue: "Desktops & Displays", table: "BrowserDevices", bundle: .module)
            case "smart-display":
                String(localized: "browserDevices.category.smartDisplay", defaultValue: "Smart Displays", table: "BrowserDevices", bundle: .module)
            default: String(localized: "browserDevices.group.phone", defaultValue: "Phones", table: "BrowserDevices", bundle: .module)
            }
        }

        /// A rumored device's row: "iPhone 18 (Rumored)".
        static func rumored(_ title: String) -> String {
            String(localized: "browserDevices.rumored", defaultValue: "\(title) (Rumored)", table: "BrowserDevices", bundle: .module)
        }

        /// The brand submenu of phones whose maker the list does not name.
        static var otherBrand: String {
            String(localized: "browserDevices.brand.other", defaultValue: "Other", table: "BrowserDevices", bundle: .module)
        }

        /// The search field's placeholder in All Devices.
        static var search: String {
            String(localized: "browserDevices.search", defaultValue: "Search Devices", table: "BrowserDevices", bundle: .module)
        }

        /// The disabled row a search with no match shows.
        static var noMatch: String {
            String(localized: "browserDevices.noMatch", defaultValue: "No Matching Devices", table: "BrowserDevices", bundle: .module)
        }

        /// The daemon's orientation names (vertical, horizontal, vertical-spanned, horizontal-spanned).
        static func orientation(_ name: String) -> String {
            switch name {
            case "vertical": String(localized: "browserDevices.portrait", defaultValue: "Portrait", table: "BrowserDevices", bundle: .module)
            case "horizontal": String(localized: "browserDevices.landscape", defaultValue: "Landscape", table: "BrowserDevices", bundle: .module)
            case "vertical-spanned":
                String(localized: "browserDevices.unfoldedPortrait", defaultValue: "Unfolded, Portrait", table: "BrowserDevices", bundle: .module)
            default:
                String(localized: "browserDevices.unfoldedLandscape", defaultValue: "Unfolded, Landscape", table: "BrowserDevices", bundle: .module)
            }
        }
    }
}
