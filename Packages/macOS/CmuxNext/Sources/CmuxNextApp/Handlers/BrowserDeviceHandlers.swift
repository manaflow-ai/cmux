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

    /// Fit as 16:9 Desktop (cx-va1wd): on sends `browser.tab.emulate {fit: "16:9"}`, off clears the emulation.
    @MainActor static func toggleFit(_ invocation: ActionInvocation, _ context: AppActionContext) {
        guard let (tab, pane) = context.daemonTab(invocation), let resource = tab.resourceID else { return }
        let daemon = context.services.daemon(for: pane)
        if fitting(tab) { return daemon.send("browser.tab.emulate.clear") { try await $0.state.clearTabEmulation(resource) } }
        daemon.send("browser.tab.emulate") { try await $0.state.fitTab(resource, aspect: "16:9") }
    }

    /// The device menu's Fit row (nil when the daemon cannot fit).
    @MainActor static func fitToggle(_ invocation: ActionInvocation, _ context: AppActionContext) -> (@MainActor () -> Void)? {
        { toggleFit(invocation, context) }
    }

    @MainActor static func fitting(_ tab: TabModel) -> Bool {
        BrowserDeviceMenu.isFit(record: tab.emulation.flatMap { try? JSONEncoder().encode($0) })
    }

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("browserFitDesktop", run: { invocation in
            _ = try context.page(invocation)
            guard let (_, pane) = context.daemonTab(invocation) else { throw ActionFailure(message: MiscHandlerStrings.noBrowser) }
            let daemon = context.services.daemon(for: pane)
            guard daemon.supports(DaemonCapabilities.shared.browserFit) else {
                throw ActionFailure(message: daemon.missingCapabilityMessage(DaemonCapabilities.shared.browserFit))
            }
            toggleFit(invocation, context)
        })
        ActionTargetTitles.setState("browserFitDesktop", in: registry) { invocation in context.daemonTab(invocation).map { fitting($0.tab) } }
        // The focused pane's selected tab, looked up without a refusal (the palette builds rows with it).
        ActionTargetTitles.setPaletteState("browserFitDesktop", in: registry) {
            guard let pane = context.services.windows.active?.focusedPane, let id = pane.stripModel.selectedID, let tab = pane.tab(id) else { return false }
            return fitting(tab)
        }
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
            let fitting = BrowserDeviceMenu.isFit(record: current)
            let fitRow = daemon.supports(DaemonCapabilities.shared.browserFit) ? fitToggle(invocation, context) : nil
            Task { @MainActor in
                do {
                    let list = try await daemon.perform("browser.devices.list") { try await $0.state.browserDevices() }
                    let menu = BrowserDeviceMenu(devices: BrowserDeviceMenu.devices(list: (try? JSONEncoder().encode(list)) ?? Data()),
                                                 current: BrowserDeviceMenu.current(record: current), isFitting: fitting,
                                                 toggleFit: fitRow, choose: choose).menu()
                    presentedMenu = menu
                    chrome.toolbarButtons.present(menu, from: .overflow)
                } catch {
                    registry.refuse(RefusalStrings.describe(error))
                }
            }
        })
    }
}
