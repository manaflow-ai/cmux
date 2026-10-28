@testable import CmuxNextApp
import CmuxNextFeatures
import CmuxNextSettings
import Testing

/// The Debug toggles `memory.discard.<kind>` are the local overrides of the
/// default-off features they name: each key is one feature's `replaces`, so the launch reads it
/// (`FeatureLaunchLocalOverrides`), and Debug Settings lists every one.
@MainActor @Suite struct MemorySaverSettingDebugToggleTests {
    @Test func everyDiscardToggleOverridesExactlyOneDefaultOffFeature() throws {
        for toggle in MemoryDiscardToggles.toggles {
            let features = Feature.registered.filter { $0.replaces.contains(toggle.key) }
            let feature = try #require(features.first, "no feature takes \(toggle.key) as its local override")
            #expect(features.count == 1, "\(toggle.key) overrides \(features.map(\.name))")
            #expect(feature.defaults == FeatureDefaults(all: false), "\(feature.name) is on somewhere by default")
            #expect(FeatureLaunchLocalOverrides(tunables: [toggle.key: true]).localOverride(for: feature) == true,
                    "\(toggle.key) on does not turn \(feature.name) on at launch")
        }
    }

    @Test func debugSettingsListsEveryToggle() {
        let catalog = Set(TunableCatalog.all.map(\.key))
        for toggle in MemoryDiscardToggles.toggles {
            #expect(catalog.contains(toggle.key), "Debug Settings does not list \(toggle.key)")
        }
    }
}
