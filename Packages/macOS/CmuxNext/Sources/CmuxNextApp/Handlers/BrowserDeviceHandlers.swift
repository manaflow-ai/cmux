import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextWindowRules

/// `browserDevice` (Emulate Device…): no argument draws the daemon's list (`browser.devices.list`) as Chrome's device
/// menu; `device` / `orientation` send `browser.tab.emulate` (`device: none` clears). The page applies the tab record's
/// `extra.emulation`; agents use `cmux tab <tab> emulate`. Fits: cx-va1wd, cx-2ftlq, cx-qby5j (browser-fit-v1).
enum BrowserDeviceHandlers {
    /// The device menu while it is open (diagnostics: `debug.menu`).
    @MainActor static weak var presentedMenu: NSMenu?

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        // browserFitDesktop / browserFitDesktop1280 toggle one fit; browserFit sets the fit its argument names ("off" clears);
        // palette state reads the focused tab without a refusal. The table and the change are Rust's (cmux-window-rules `browser`).
        let rules = WindowRules()
        for action in rules.fitActions() ?? [] {
            let id = ActionID(rawValue: action.action), fixed = action.fit
            registry.bind(id, run: { invocation in
                guard let (tab, pane) = context.daemonTab(invocation), let resource = tab.resourceID,
                      let change = rules.fit(fixed: fixed, asked: invocation["fit"]?.stringValue, current: tab.fitValue) else {
                    throw ActionFailure(message: MiscHandlerStrings.noBrowser)
                }
                let daemon = context.services.daemon(for: pane), capability = (change.capability == "browserFitWidth" ? DaemonCapability.browserFitWidth : .browserFit).rawValue
                guard daemon.supports(capability) else { throw ActionFailure(message: daemon.missingCapabilityMessage(capability)) }
                daemon.send("browser.tab.emulate") { try await $0.state.setTabFit(resource, fit: change.fit) }
            })
            guard let fixed else { ActionTargetTitles.setChoiceState(id, in: registry) { context.daemonTab(ActionInvocation(target: $0))?.tab.fitValue }; continue }
            ActionTargetTitles.setState(id, in: registry) { context.daemonTab($0).map { $0.tab.fitValue == fixed } }
            ActionTargetTitles.setPaletteState(id, in: registry) { context.services.windows.active?.focusedPane?.selectedTab?.fitValue == fixed }
        }
        // The fit bar under a fitted page runs browserFit on its tab's pane (nil fit: the palette asks).
        BrowserFitFrameView.perform = { tab, fit in
            guard let pane = context.services.locateTab(tab)?.1 else { return }
            _ = registry.perform("browserFit", invocation: ActionInvocation(target: ActionTargetRef(kind: .pane, id: pane.id), arguments: fit.map { ["fit": .string($0)] } ?? [:]).onMachine(context.services.daemon(for: pane).machineID))
        }
        registry.bind("browserDevice", run: { invocation in
            let entry = try context.page(invocation)
            guard let (tab, pane) = context.daemonTab(invocation), let resource = tab.resourceID else { throw ActionFailure(message: MiscHandlerStrings.noBrowser) }
            let daemon = context.services.daemon(for: pane)
            guard daemon.supports(DaemonCapability.browserDevices.rawValue) else { throw ActionFailure(message: daemon.missingCapabilityMessage(DaemonCapability.browserDevices.rawValue)) }
            let choose: @MainActor (String?, String?) -> Void = { device, orientation in daemon.send("browser.tab.emulate") { try await $0.state.setTabEmulation(resource, device: device, orientation: orientation) } }
            if let emulation = rules.device(invocation["device"]?.stringValue, orientation: invocation["orientation"]?.stringValue) {
                return choose(emulation.device, emulation.orientation)
            }
            let (state, current) = (entry.state, tab.emulation.flatMap { try? JSONEncoder().encode($0) })
            Task { @MainActor in
                do {
                    let list = try await daemon.perform("browser.devices.list") { try await $0.state.browserDevices() }
                    let menu = BrowserDeviceMenu(devices: BrowserDeviceMenu.devices(list: (try? JSONEncoder().encode(list)) ?? Data()),
                                                 current: BrowserDeviceMenu.current(record: current), fit: tab.fitValue,
                                                 fits: rules.menuFits(fit: daemon.supports(DaemonCapability.browserFit.rawValue),
                                                                      fitWidth: daemon.supports(DaemonCapability.browserFitWidth.rawValue)),
                                                 toggleFit: { _ = registry.perform($0 == "1280" ? "browserFitDesktop1280" : "browserFitDesktop", invocation: invocation) }, choose: choose).menu()
                    presentedMenu = menu; state.chrome?.toolbarButtons.present(menu, from: .overflow, themed: true)
                } catch { registry.refuse(RefusalStrings.describe(error)) }
            }
        })
    }
}
