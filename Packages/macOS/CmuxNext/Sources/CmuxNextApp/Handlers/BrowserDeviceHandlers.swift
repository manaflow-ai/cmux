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
            // nil device: No Device (`browser.tab.emulate.clear`); nil orientation: the device's first.
            let choose: @MainActor (String?, String?) -> Void = { device, orientation in
                guard let device else { return daemon.send("browser.tab.emulate.clear") { try await $0.state.clearTabEmulation(resource) } }
                daemon.send("browser.tab.emulate") { try await $0.state.emulateTab(resource, device: device.isEmpty ? nil : device, orientation: orientation) }
            }
            let device = invocation["device"]?.stringValue?.trimmingCharacters(in: .whitespaces)
            let orientation = invocation["orientation"]?.stringValue
            if device != nil || orientation != nil { return choose(device?.lowercased() == "none" ? nil : device ?? "", orientation) }
            let (chrome, current) = (entry.chrome, tab.emulation.flatMap { try? JSONEncoder().encode($0) })
            Task { @MainActor in
                do {
                    let list = try await daemon.perform("browser.devices.list") { try await $0.state.browserDevices() }
                    let menu = BrowserDeviceMenu(devices: BrowserDeviceMenu.devices(list: (try? JSONEncoder().encode(list)) ?? Data()),
                                                 current: BrowserDeviceMenu.current(record: current), choose: choose).menu()
                    presentedMenu = menu
                    chrome.toolbarButtons.present(menu, from: .overflow)
                } catch {
                    registry.refuse(RefusalStrings.describe(error))
                }
            }
        })
    }
}
