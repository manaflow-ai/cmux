import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDaemon

/// `browserDevice` (Emulate Device…): Chrome's device toolbar for both
/// engines. The daemon owns the device list (`browser.devices.list`) and the
/// tab's emulation (`browser.tab.emulate`, `browser.tab.emulate.clear`); the
/// page applies the tab record's `extra.emulation`. This handler only draws
/// the daemon's list as a menu and sends the person's choice back.
///
/// | argument | effect |
/// | --- | --- |
/// | none | shows the device menu (from the toolbar's More button) |
/// | `device: <title>` | `browser.tab.emulate` (the daemon matches the title) |
/// | `device: none` | `browser.tab.emulate.clear` |
/// | `orientation` | passed to the daemon as given (portrait, landscape, unfolded-portrait, unfolded-landscape) |
///
/// Scripts and agents use the daemon directly: `cmux tab <tab> emulate`.
enum BrowserDeviceHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("browserDevice", run: { invocation in
            let entry = try context.page(invocation)
            guard let (tab, pane) = context.daemonTab(invocation), let resource = tab.resourceID else {
                throw ActionFailure(message: MiscHandlerStrings.noBrowser)
            }
            let daemon = context.services.daemon(for: pane)
            guard daemon.supports(DaemonCapabilities.shared.browserDevices) else {
                throw ActionFailure(message: daemon.missingCapabilityMessage(DaemonCapabilities.shared.browserDevices))
            }
            let device = invocation["device"]?.stringValue?.trimmingCharacters(in: .whitespaces)
            let orientation = invocation["orientation"]?.stringValue
            if device?.lowercased() == "none" {
                daemon.send("browser.tab.emulate.clear") { try await $0.state.clearTabEmulation(resource) }
                return
            }
            if device?.isEmpty == false || orientation != nil {
                daemon.send("browser.tab.emulate") {
                    try await $0.state.emulateTab(resource, device: device?.isEmpty == false ? device : nil, orientation: orientation)
                }
                return
            }
            let chrome = entry.chrome
            let current = tab.emulation
            Task { @MainActor in
                guard let list = try? await daemon.perform("browser.devices.list", { try await $0.state.browserDevices() }) else { return }
                let menu = menu(list: list, current: current) { device, orientation in
                    if let device {
                        daemon.send("browser.tab.emulate") { try await $0.state.emulateTab(resource, device: device, orientation: orientation) }
                    } else {
                        daemon.send("browser.tab.emulate.clear") { try await $0.state.clearTabEmulation(resource) }
                    }
                }
                chrome.toolbarButtons.present(menu, from: .overflow)
            }
        })
    }

    /// The daemon's list as Chrome's device menu: No Device, the current
    /// device's orientations, the default-visible devices by Chrome's
    /// categories, the custom devices, and every device under All Devices.
    /// Each row sends `choose(title, orientation)`; nil title is No Device.
    static func menu(list: JSONValue, current: JSONValue?,
                     choose: @escaping @MainActor (String?, String?) -> Void) -> NSMenu {
        let devices: [[String: JSONValue]] = {
            guard case .object(let fields) = list, case .array(let items)? = fields["devices"] else { return [] }
            return items.compactMap { if case .object(let device) = $0 { device } else { nil } }
        }()
        let currentFields: [String: JSONValue]? = if case .object(let fields)? = current { fields } else { nil }
        let currentTitle = currentFields?["device"]?.stringValue
        let menu = NSMenu()
        func add(_ title: String, to menu: NSMenu, checked: Bool = false, toolTip: String? = nil, _ action: @escaping @MainActor () -> Void) {
            let closure = ActionMenuClosure(action)
            let item = NSMenuItem(title: title, action: #selector(ActionMenuClosure.run), keyEquivalent: "")
            item.target = closure
            item.representedObject = closure
            item.state = checked ? .on : .off
            item.toolTip = toolTip
            menu.addItem(item)
        }
        func addDevices(_ list: [[String: JSONValue]], to menu: NSMenu) {
            for device in list {
                guard let title = device["title"]?.stringValue else { continue }
                add(title, to: menu, checked: title == currentTitle, toolTip: details(device)) { choose(title, nil) }
            }
        }
        add(DeviceStrings.noDevice, to: menu, checked: currentFields == nil) { choose(nil, nil) }
        if let currentTitle, case .array(let names)? = currentFields?["orientations"], names.count > 1 {
            menu.addItem(.separator())
            for name in names.compactMap(\.stringValue) {
                add(DeviceStrings.orientation(name), to: menu, checked: name == currentFields?["orientation"]?.stringValue) {
                    choose(currentTitle, name)
                }
            }
        }
        let builtIn = devices.filter { $0["origin"]?.stringValue != "custom" }
        for category in DeviceStrings.Category.allCases {
            let shown = builtIn.filter { DeviceStrings.Category($0) == category && $0["show-by-default"] != .bool(false) }
            guard !shown.isEmpty else { continue }
            menu.addItem(.sectionHeader(title: DeviceStrings.title(category)))
            addDevices(shown, to: menu)
        }
        let custom = devices.filter { $0["origin"]?.stringValue == "custom" }
        if !custom.isEmpty {
            menu.addItem(.sectionHeader(title: DeviceStrings.custom))
            addDevices(custom, to: menu)
        }
        menu.addItem(.separator())
        let all = NSMenu()
        for category in DeviceStrings.Category.allCases {
            let listed = builtIn.filter { DeviceStrings.Category($0) == category }
            guard !listed.isEmpty else { continue }
            all.addItem(.sectionHeader(title: DeviceStrings.title(category)))
            addDevices(listed, to: all)
        }
        let allItem = NSMenuItem(title: DeviceStrings.allDevices, action: nil, keyEquivalent: "")
        allItem.submenu = all
        menu.addItem(allItem)
        return menu
    }

    /// "W × H, device pixel ratio R" of the device's portrait screen.
    private static func details(_ device: [String: JSONValue]) -> String? {
        guard case .object(let screen)? = device["screen"], case .object(let vertical)? = screen["vertical"],
              let width = vertical["width"]?.doubleValue, let height = vertical["height"]?.doubleValue,
              let ratio = screen["device-pixel-ratio"]?.doubleValue else { return nil }
        return DeviceStrings.details(width: Int(width), height: Int(height), ratio: ratio)
    }
}

/// The device menu's text (BrowserDevices.xcstrings).
nonisolated enum DeviceStrings {
    /// Chrome's device menu sections, in Chrome's order (DeviceModeView
    /// `deviceCategory`), read from each device's own `type` and flags.
    enum Category: CaseIterable {
        case mobile, foldable, tabletDesktop, smartDisplay

        init(_ device: [String: JSONValue]) {
            let type = device["type"]?.stringValue ?? ""
            if type == "foldable" || device["foldable-screen"] == .bool(true) || device["dual-screen"] == .bool(true) {
                self = .foldable
            } else if type == "smart-display" {
                self = .smartDisplay
            } else if ["tablet", "notebook", "desktop"].contains(type) {
                self = .tabletDesktop
            } else {
                self = .mobile
            }
        }
    }

    static var noDevice: String { String(localized: "browserDevices.none", defaultValue: "No Device", table: "BrowserDevices", bundle: .module) }
    static var allDevices: String { String(localized: "browserDevices.all", defaultValue: "All Devices", table: "BrowserDevices", bundle: .module) }
    static var custom: String { String(localized: "browserDevices.custom", defaultValue: "Custom", table: "BrowserDevices", bundle: .module) }

    static func details(width: Int, height: Int, ratio: Double) -> String {
        let ratioText = ratio.formatted(.number.precision(.fractionLength(0...3)))
        return String(localized: "browserDevices.details", defaultValue: "\(width) × \(height), device pixel ratio \(ratioText)",
                      table: "BrowserDevices", bundle: .module)
    }

    static func title(_ category: Category) -> String {
        switch category {
        case .mobile: String(localized: "browserDevices.category.mobile", defaultValue: "Mobile", table: "BrowserDevices", bundle: .module)
        case .foldable: String(localized: "browserDevices.category.foldable", defaultValue: "Foldables", table: "BrowserDevices", bundle: .module)
        case .tabletDesktop:
            String(localized: "browserDevices.category.tabletDesktop", defaultValue: "Tablets & Desktops", table: "BrowserDevices", bundle: .module)
        case .smartDisplay:
            String(localized: "browserDevices.category.smartDisplay", defaultValue: "Smart Displays", table: "BrowserDevices", bundle: .module)
        }
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
