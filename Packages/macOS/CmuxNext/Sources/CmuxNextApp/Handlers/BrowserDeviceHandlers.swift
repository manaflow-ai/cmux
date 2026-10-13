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
    /// The device menu while it is open (diagnostics: `debug.menu`).
    @MainActor static weak var presentedMenu: NSMenu?

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
                let list: JSONValue
                do {
                    list = try await daemon.perform("browser.devices.list") { try await $0.state.browserDevices() }
                } catch {
                    registry.refuse(RefusalStrings.describe(error))
                    return
                }
                let menu = BrowserDeviceMenu(devices: devices(list), current: Self.current(current)) { device, orientation in
                    if let device {
                        daemon.send("browser.tab.emulate") { try await $0.state.emulateTab(resource, device: device, orientation: orientation) }
                    } else {
                        daemon.send("browser.tab.emulate.clear") { try await $0.state.clearTabEmulation(resource) }
                    }
                }.menu()
                presentedMenu = menu
                chrome.toolbarButtons.present(menu, from: .overflow)
            }
        })
    }

    /// The rows of the daemon's list (`browser.devices.list`).
    static func devices(_ list: JSONValue) -> [BrowserDeviceMenu.Device] {
        guard case .object(let fields) = list, case .array(let items)? = fields["devices"] else { return [] }
        return items.compactMap { item in
            guard case .object(let device) = item, let title = device["title"]?.stringValue else { return nil }
            var size: (width: Int, height: Int, ratio: Double)?
            if case .object(let screen)? = device["screen"], case .object(let vertical)? = screen["vertical"],
               let width = vertical["width"]?.doubleValue, let height = vertical["height"]?.doubleValue,
               let ratio = screen["device-pixel-ratio"]?.doubleValue {
                size = (Int(width), Int(height), ratio)
            }
            return BrowserDeviceMenu.Device(title: title, category: device["category"]?.stringValue ?? "mobile",
                                            shownByDefault: device["show-by-default"] != .bool(false),
                                            isCustom: device["origin"]?.stringValue == "custom", size: size)
        }
    }

    /// The tab record's `extra.emulation`, as the menu shows it.
    static func current(_ record: JSONValue?) -> BrowserDeviceMenu.Current? {
        guard case .object(let fields)? = record, let title = fields["device"]?.stringValue else { return nil }
        let names: [String] = if case .array(let values)? = fields["orientations"] { values.compactMap(\.stringValue) } else { [] }
        return BrowserDeviceMenu.Current(title: title, orientation: fields["orientation"]?.stringValue ?? "", orientations: names)
    }
}
