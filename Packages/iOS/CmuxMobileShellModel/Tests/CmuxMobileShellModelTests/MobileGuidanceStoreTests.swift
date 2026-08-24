import Foundation
import Testing

@testable import CmuxMobileShellModel

/// Behavior tests for ``MobileGuidanceStore`` using isolated defaults suites.
@MainActor
@Suite struct MobileGuidanceStoreTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "MobileGuidanceStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func tipsStartVisibleAndDismissDurably() {
        let defaults = makeDefaults()
        let store = MobileGuidanceStore(defaults: defaults)
        #expect(!store.isDismissed(.enablePushAlerts))

        store.dismiss(.enablePushAlerts)

        #expect(store.isDismissed(.enablePushAlerts))
        #expect(!store.isDismissed(.openFirstWorkspace))
        #expect(MobileGuidanceStore(defaults: defaults).isDismissed(.enablePushAlerts))
    }

    @Test func resetForgetsEveryDismissal() {
        let defaults = makeDefaults()
        let store = MobileGuidanceStore(defaults: defaults)
        store.dismiss(.enablePushAlerts)
        store.dismiss(.openFirstWorkspace)

        store.reset()

        #expect(!store.isDismissed(.enablePushAlerts))
        #expect(!store.isDismissed(.openFirstWorkspace))
        #expect(!MobileGuidanceStore(defaults: defaults).isDismissed(.enablePushAlerts))
    }

    @Test func unknownStoredValuesAreTolerated() {
        let defaults = makeDefaults()
        defaults.set(
            ["someRetiredTip.v1", MobileGuidanceTip.enablePushAlerts.rawValue],
            forKey: MobileGuidanceStore.dismissedKey
        )
        let store = MobileGuidanceStore(defaults: defaults)

        #expect(store.isDismissed(.enablePushAlerts))
        #expect(!store.isDismissed(.openFirstWorkspace))
    }
}
