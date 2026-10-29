import AppKit
@testable import CmuxNextApp
import CmuxNextFeatures
import Testing

/// The production wiring of `memoryOpenPanelOnFirstUse`: the app's file picker
/// (`AppServices.openPanel`, built inside `init` through `cache`) takes its policy from the features passed to
/// `init`. On, the launch's afterStartup warm-up (`LaunchFirstOpenWarmups.warmOpenPanel`, the same
/// `warmWhenIdle()` call) arms nothing and makes no panel; off (the default), it arms the made-ahead warm-up.
/// The test host's event loop does not run, so an armed warm-up's check never makes an `NSOpenPanel` here.
@MainActor @Suite(.serialized) struct OpenPanelFirstUseWiringTests {
    private static func services(enabling names: Set<String> = []) -> AppServices {
        _ = NSApplication.shared
        let features = FeatureList(registry: FeatureRegistry(), channel: .dev,
                                   overrides: FeatureOverrides(environmentEnabled: names))
        return AppServices(environment: AppEnvironment.current([:]), features: features)
    }

    @Test func theFeatureOnMakesNoPanelAtAppStart() {
        let services = Self.services(enabling: [Feature.memoryOpenPanelOnFirstUse.name])
        #expect(services.features.isEnabled(.memoryOpenPanelOnFirstUse))

        services.openPanel.warmWhenIdle()  // the launch's afterStartup post

        #expect(!services.openPanel.isWarming, "the app armed a picker warm-up at start with the feature on")
        #expect(!services.openPanel.isMade, "the app made a picker at start with the feature on")
    }

    @Test func theFeatureOffArmsTheWarmUpAtAppStart() {
        let services = Self.services()
        #expect(!services.features.isEnabled(.memoryOpenPanelOnFirstUse), "the feature must default off")

        services.openPanel.warmWhenIdle()  // the launch's afterStartup post

        #expect(services.openPanel.isWarming, "the default policy no longer arms the picker warm-up at start")
    }
}
