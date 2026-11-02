import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextFeatures
import CmuxNextSettingsWindow
import CmuxNextWakeups
import Testing

/// Show / Hide Host Pressure Warning (Lawrence 2026-11-02: "get rid of host-pressure warning by default, can be
/// enabled in cmd shift p tho"): the palette pair sets the Debug toggle `hostPressure.enabled`, the feature
/// `hostPressure`'s local override, and a window's indicator follows the store with no other call: Show subscribes it
/// (the monitor and its 15 s timer start); Hide unsubscribes it (the monitor stops) and hides the gauge, also when the
/// launch resolved the feature on from the Debug Settings file.
@MainActor @Suite struct HostPressureWarningActionsTests {
    private static func rig(launchLocal: Bool?) -> (TunableStore, ActionRegistry, AppServices) {
        let store = TunableStore()
        store.register(HostPressureTunables.all)
        store.activate(file: nil)
        let toggles = launchLocal.map { [HostPressureTunables.enabled.key: $0] } ?? [:]
        if let launchLocal { _ = store.set(HostPressureTunables.enabled.key, launchLocal.tunableValue) }
        let features = FeatureList(registry: FeatureRegistry(), channel: .dev,
                                   local: FeatureLaunchLocalOverrides(labs: FeatureLocalOverrides(), tunables: toggles))
        let registry = ActionRegistry(catalog: ActionCatalog.all)
        DebugTunableSwitchActions(show: "hostPressure.showWarning", hide: "hostPressure.hideWarning",
                                  tunable: HostPressureTunables.enabled, store: store).bind(into: registry)
        return (store, registry, AppServices(environment: AppEnvironment.current(["CMUX_NEXT_SHOWCASE": "1"]), features: features))
    }

    @Test(arguments: [nil, true] as [Bool?])
    func showAndHideSetTheToggleAndTheIndicatorFollows(launchLocal: Bool?) async {
        let (store, registry, services) = Self.rig(launchLocal: launchLocal)
        let rig = MainDeadlineRig(), node = VisibilityNode(root: "window", own: .visible)
        var service: HostPressureService?
        let indicator = HostPressureIndicatorView(services: services, store: store, mainWork: rig.deadlines.work, nodeOf: { _ in node },
                                                  eventsOf: { WindowEvents(window: $0, center: NotificationCenter()) },
                                                  service: {
                                                      let made = hostPressureTestService(store, rig: rig)
                                                      service = made
                                                      return made
                                                  }) {}
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(indicator)
        #expect(indicator.isSampling == (launchLocal == true))

        #expect(registry.perform("hostPressure.showWarning"))
        hostPressureSpin(until: { indicator.isSampling }, rig: rig)
        #expect(indicator.isSampling)
        #expect(await service?.monitorIsRunning() == true)
        // Show again changes nothing.
        #expect(registry.perform("hostPressure.showWarning"))
        #expect(service?.subscriberCount == 1)

        // Hide says off, so a launch that resolved the feature on from the file stops too.
        #expect(registry.perform("hostPressure.hideWarning"))
        #expect(HostPressureTunables.enabled.override(in: store) == false)
        hostPressureSpin(until: { !indicator.isSampling }, rig: rig)
        #expect(!indicator.isSampling)
        #expect(await service?.monitorIsRunning() == false)
        #expect(indicator.isHidden)
        indicator.removeFromSuperview()
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
