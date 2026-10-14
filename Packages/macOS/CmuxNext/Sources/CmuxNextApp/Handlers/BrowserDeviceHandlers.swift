import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextDaemon

/// `browserDevice` (Emulate Device…): no argument draws the daemon's list
/// (`browser.devices.list`) as Chrome's device menu; `device` / `orientation`
/// send `browser.tab.emulate` (`device: none` clears). The page applies the
/// tab record's `extra.emulation`; agents use `cmux tab <tab> emulate`.
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
                let menu = BrowserDeviceMenu(devices: BrowserDeviceMenu.devices(list: (try? JSONEncoder().encode(list)) ?? Data()),
                                             current: BrowserDeviceMenu.current(record: current.flatMap { try? JSONEncoder().encode($0) })) { device, orientation in
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
}
