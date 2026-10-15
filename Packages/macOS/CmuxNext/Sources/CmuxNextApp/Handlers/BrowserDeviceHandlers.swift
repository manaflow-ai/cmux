import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextDaemon

/// `browserDevice` (Emulate Device…): no argument draws the daemon's list
/// (`browser.devices.list`) as Chrome's device menu; `device` / `orientation`
/// send `browser.tab.emulate` (`device: none` clears). The page applies the
/// tab record's `extra.emulation`; agents use `cmux tab <tab> emulate`. `browserFitDesktop` toggles Fit as
/// 16:9 Desktop (cx-va1wd, browser-fit-v1); its palette state reads the focused tab without a refusal.
enum BrowserDeviceHandlers {
    /// The device menu while it is open (diagnostics: `debug.menu`).
    @MainActor static weak var presentedMenu: NSMenu?

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("browserFitDesktop", run: { invocation in
            _ = try context.page(invocation)
            guard let (tab, pane) = context.daemonTab(invocation), let resource = tab.resourceID else { throw ActionFailure(message: MiscHandlerStrings.noBrowser) }
            let (daemon, on) = (context.services.daemon(for: pane), !tab.fitsDesktop)
            guard daemon.supports(DaemonCapabilities.shared.browserFit) else { throw ActionFailure(message: daemon.missingCapabilityMessage(DaemonCapabilities.shared.browserFit)) }
            daemon.send("browser.tab.emulate") { try await $0.state.setTabFit(resource, on: on) }
        })
        ActionTargetTitles.setState("browserFitDesktop", in: registry) { context.daemonTab($0)?.tab.fitsDesktop }
        ActionTargetTitles.setPaletteState("browserFitDesktop", in: registry) { context.services.windows.active?.focusedPane?.selectedTab?.fitsDesktop == true }
        registry.bind("browserDevice", run: { invocation in
            let entry = try context.page(invocation)
            guard let (tab, pane) = context.daemonTab(invocation), let resource = tab.resourceID else { throw ActionFailure(message: MiscHandlerStrings.noBrowser) }
            let daemon = context.services.daemon(for: pane)
            guard daemon.supports(DaemonCapabilities.shared.browserDevices) else { throw ActionFailure(message: daemon.missingCapabilityMessage(DaemonCapabilities.shared.browserDevices)) }
            let choose: @MainActor (String?, String?) -> Void = { device, orientation in daemon.send("browser.tab.emulate") { try await $0.state.setTabEmulation(resource, device: device, orientation: orientation) } }
            let (device, orientation) = (invocation["device"]?.stringValue?.trimmingCharacters(in: .whitespaces), invocation["orientation"]?.stringValue)
            if device != nil || orientation != nil { return choose(device?.lowercased() == "none" ? nil : device ?? "", orientation) }
            let (chrome, current) = (entry.chrome, tab.emulation.flatMap { try? JSONEncoder().encode($0) })
            Task { @MainActor in
                do {
                    let list = try await daemon.perform("browser.devices.list") { try await $0.state.browserDevices() }
                    let menu = BrowserDeviceMenu(devices: BrowserDeviceMenu.devices(list: (try? JSONEncoder().encode(list)) ?? Data()),
                                                 current: BrowserDeviceMenu.current(record: current), isFitting: tab.fitsDesktop, showsFit: daemon.supports(DaemonCapabilities.shared.browserFit),
                                                 toggleFit: { _ = registry.perform("browserFitDesktop", invocation: invocation) }, choose: choose).menu()
                    presentedMenu = menu
                    chrome.toolbarButtons.present(menu, from: .overflow)
                } catch { registry.refuse(RefusalStrings.describe(error)) }
            }
        })
    }
}
