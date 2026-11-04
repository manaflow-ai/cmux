import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextFeatures
import CmuxNextHostPressure
import CmuxNextWakeups
import Foundation
import Testing

/// The host pressure indicator is off unless a person turns it on (Lawrence 2026-11-02, feat #32374): a chrome-parity
/// dogfood build, whose tag turns its switch set on, shows no gauge and starts no 15 s host read with nothing set.
@MainActor @Suite(.serialized)
struct HostPressureDogfoodDefaultTests {
    @Test func aChromeParityDogfoodBuildDoesNotSampleTheHostByDefault() {
        let overrides = FeatureOverrides(buildDefaults: FeatureDogfoodSet.chromeParity.buildDefaults(forTag: "chrome-parity-v2-1"))
        let features = FeatureList(registry: FeatureRegistry(), channel: .dev, overrides: overrides)
        let services = AppServices(environment: AppEnvironment.current(["CMUX_NEXT_SHOWCASE": "1"]), features: features)
        let store = TunableStore()
        store.register(HostPressureTunables.all)
        store.activate(file: nil)
        let rig = MainDeadlineRig(), node = VisibilityNode(root: "window", own: .visible)
        let indicator = HostPressureIndicatorView(
            services: services, store: store, mainWork: rig.deadlines.work, nodeOf: { _ in node },
            service: { hostPressureTestService(store, rig: rig) }) {}
        #expect(!indicator.sampling.enabled, "a dogfood build turned the host pressure gauge on by default")
    }
}
