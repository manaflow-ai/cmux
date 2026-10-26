import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextDaemon

/// `browserDevice` (Emulate Device…): no argument draws the daemon's list (`browser.devices.list`) as Chrome's device
/// menu; `device` / `orientation` send `browser.tab.emulate` (`device: none` clears). The page applies the tab record's
/// `extra.emulation`; agents use `cmux tab <tab> emulate`. Fits: cx-va1wd, cx-2ftlq, cx-qby5j (browser-fit-v1).
enum BrowserDeviceHandlers {
    /// The device menu while it is open (diagnostics: `debug.menu`).
    @MainActor static weak var presentedMenu: NSMenu?

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        // browserFitDesktop / browserFitDesktop1280 toggle one fit; browserFit sets the fit its argument names ("off" clears);
        // palette state reads the focused tab without a refusal.
        let fits: [(ActionID, String?)] = [("browserFitDesktop", "16:9"), ("browserFitDesktop1280", "1280"), ("browserFit", nil)]
        for (id, fixed) in fits {
            registry.bind(id, run: { invocation in
                guard let (tab, pane) = context.daemonTab(invocation), let resource = tab.resourceID else { throw ActionFailure(message: MiscHandlerStrings.noBrowser) }
                guard let asked = fixed ?? invocation["fit"]?.stringValue?.trimmingCharacters(in: .whitespaces), !asked.isEmpty else { throw ActionFailure(message: MiscHandlerStrings.noBrowser) }
                let next: String? = asked.lowercased() == "off" || (fixed != nil && tab.fitValue == fixed) ? nil : asked
                let (daemon, capability) = (context.services.daemon(for: pane), next.flatMap { Int($0) } != nil ? DaemonCapability.browserFitWidth.rawValue : DaemonCapability.browserFit.rawValue)
                guard daemon.supports(capability) else { throw ActionFailure(message: daemon.missingCapabilityMessage(capability)) }
                daemon.send("browser.tab.emulate") { try await $0.state.setTabFit(resource, fit: next) }
            })
            guard let fixed else { ActionTargetTitles.setChoiceState(id, in: registry) { context.daemonTab(ActionInvocation(target: $0))?.tab.fitValue }; continue }
            ActionTargetTitles.setState(id, in: registry) { context.daemonTab($0).map { $0.tab.fitValue == fixed } }
            ActionTargetTitles.setPaletteState(id, in: registry) { context.services.windows.active?.focusedPane?.selectedTab?.fitValue == fixed }
        }
        // The fit bar under a fitted page runs browserFit on its tab's pane (nil fit: the palette asks).
        BrowserFitFrameView.perform = { tab, fit in
            guard let pane = context.services.locateTab(tab)?.1 else { return }
            _ = registry.perform("browserFit", invocation: ActionInvocation(target: ActionTargetRef(kind: .pane, id: pane.id), arguments: fit.map { ["fit": .string($0)] } ?? [:]))
        }
        registry.bind("browserDevice", run: { invocation in
            let entry = try context.page(invocation)
            guard let (tab, pane) = context.daemonTab(invocation), let resource = tab.resourceID else { throw ActionFailure(message: MiscHandlerStrings.noBrowser) }
            let daemon = context.services.daemon(for: pane)
            guard daemon.supports(DaemonCapability.browserDevices.rawValue) else { throw ActionFailure(message: daemon.missingCapabilityMessage(DaemonCapability.browserDevices.rawValue)) }
            let choose: @MainActor (String?, String?) -> Void = { device, orientation in daemon.send("browser.tab.emulate") { try await $0.state.setTabEmulation(resource, device: device, orientation: orientation) } }
            let (device, orientation) = (invocation["device"]?.stringValue?.trimmingCharacters(in: .whitespaces), invocation["orientation"]?.stringValue)
            if device != nil || orientation != nil { return choose(device?.lowercased() == "none" ? nil : device ?? "", orientation) }
            let (chrome, current) = (entry.chrome, tab.emulation.flatMap { try? JSONEncoder().encode($0) })
            Task { @MainActor in
                do {
                    let list = try await daemon.perform("browser.devices.list") { try await $0.state.browserDevices() }
                    let menu = BrowserDeviceMenu(devices: BrowserDeviceMenu.devices(list: (try? JSONEncoder().encode(list)) ?? Data()),
                                                 current: BrowserDeviceMenu.current(record: current), fit: tab.fitValue, fits: ["16:9", "1280"].filter { daemon.supports(Int($0) == nil ? DaemonCapability.browserFit.rawValue : DaemonCapability.browserFitWidth.rawValue) },
                                                 toggleFit: { _ = registry.perform($0 == "1280" ? "browserFitDesktop1280" : "browserFitDesktop", invocation: invocation) }, choose: choose).menu()
                    presentedMenu = menu; chrome.toolbarButtons.present(menu, from: .overflow, themed: true)
                } catch { registry.refuse(RefusalStrings.describe(error)) }
            }
        })
    }
}
