import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSettingsWindow
import CmuxNextTestSupport
import Testing

/// Show / Hide Host Pressure Warning (Lawrence 2026-11-02: "get rid of host-pressure warning by default, can be
/// enabled in cmd shift p tho"): the palette pair sets the Debug toggle `hostPressure.enabled`, and a window's
/// indicator follows the store with no other call: Show subscribes it (the monitor and its 15 s timer start) and
/// shows the gauge; Hide unsubscribes it (the monitor stops) and hides the gauge.
@MainActor @Suite(.closesItsWindows) struct HostPressureWarningActionsTests {
    @Test func showAndHideSetTheToggleAndTheIndicatorFollows() async {
        let store = TunableStore()
        store.register(HostPressureTunables.all)
        store.activate(file: nil)
        // A forced level, so the gauge shows once it samples (a forced level counts as seen in a window).
        _ = store.set(HostPressureTunables.force.key, HostPressureForce.warning.tunableValue)
        let registry = ActionRegistry(catalog: ActionCatalog.all)
        DebugTunableSwitchActions(show: "hostPressure.showWarning", hide: "hostPressure.hideWarning",
                                  tunable: HostPressureTunables.enabled, store: store).bind(into: registry)
        var service: HostPressureService?
        let indicator = HostPressureIndicatorView(services: AppServices(environment: AppEnvironment.current(["CMUX_NEXT_SHOWCASE": "1"])),
                                                  store: store, notifications: NotificationCenter(), windowVisible: { _ in true },
                                                  service: {
                                                      let made = HostPressureService(acpmux: nil, store: store)
                                                      service = made
                                                      return made
                                                  }) {}
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(indicator)
        // Off by default: no service, no sampling, no gauge.
        #expect(!indicator.isSampling)
        #expect(service == nil)
        #expect(indicator.isHidden)
        // Let the toggle observation start listening.
        for _ in 0 ..< 20 { await Task.yield() }

        #expect(registry.perform("hostPressure.showWarning"))
        #expect(HostPressureTunables.enabled.value(in: store))
        for _ in 0 ..< 100 where !indicator.isSampling || indicator.isHidden { await Task.yield() }
        #expect(indicator.isSampling)
        #expect(await service?.monitorIsRunning() == true)
        #expect(!indicator.isHidden)

        // Show again changes nothing.
        #expect(registry.perform("hostPressure.showWarning"))
        #expect(service?.subscriberCount == 1)

        #expect(registry.perform("hostPressure.hideWarning"))
        // Off is the default, so Hide removes the override, as the Debug Settings row does.
        #expect(store.override(HostPressureTunables.enabled.key) == nil)
        for _ in 0 ..< 100 where indicator.isSampling { await Task.yield() }
        #expect(!indicator.isSampling)
        #expect(await service?.monitorIsRunning() == false)
        #expect(indicator.isHidden)
        indicator.removeFromSuperview()
        _ = store.set(HostPressureTunables.force.key, HostPressureForce.off.tunableValue)
        service?.stop()
    }

    @Test func bothActionsAreDebugOnlyPaletteRows() {
        for id: ActionID in ["hostPressure.showWarning", "hostPressure.hideWarning"] {
            let descriptor = ActionCatalog.all.first { $0.id == id }
            #expect(descriptor?.isDebugOnly == true)
            #expect(descriptor?.surfaces.contains(.palette) == true)
        }
    }
}
