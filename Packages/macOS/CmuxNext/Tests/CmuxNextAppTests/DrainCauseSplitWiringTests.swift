import AppKit
@testable import CmuxNextApp
import CmuxNextFeatures
import Testing

/// The production wiring of `drainCauseSplit`: on, the local store's drain applies the
/// automation tail in budgeted tasks of the app's main work scheduler; off, it has no tail scheduler and every
/// frame drain applies its whole batch (the drain itself: DrainCauseSplitTests). Off by default in every channel
/// until its redesign is judged PRINCIPLED by the principled-optimization audit (cmux-ad 2026-10-29).
@MainActor @Suite(.serialized) struct DrainCauseSplitWiringTests {
    private static func services(_ overrides: FeatureOverrides, channel: Feature.Channel = .dev) -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.features = FeatureList(registry: FeatureRegistry(), channel: channel, overrides: overrides)
        return services
    }

    @Test func onTheStoreDrainsItsTailOnTheMainWorkScheduler() {
        let services = Self.services(FeatureOverrides(environmentEnabled: [Feature.drainCauseSplit.name]))
        services.installDrainTail()
        #expect(services.daemon.store.drainTailScheduler as AnyObject? === services.mainWork)
    }

    @Test func offTheStoreHasNoTailScheduler() {
        let services = Self.services(FeatureOverrides(environmentDisabled: [Feature.drainCauseSplit.name]))
        services.installDrainTail()
        #expect(services.daemon.store.drainTailScheduler == nil)
    }

    @Test func noChannelDrainsTheTailByDefault() {
        for channel in Feature.Channel.allCases {
            let services = Self.services(FeatureOverrides(), channel: channel)
            services.installDrainTail()
            #expect(services.daemon.store.drainTailScheduler == nil, "\(channel)")
        }
    }
}
