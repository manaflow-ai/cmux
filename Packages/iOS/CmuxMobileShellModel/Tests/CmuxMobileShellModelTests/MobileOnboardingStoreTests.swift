import Foundation
import Testing

@testable import CmuxMobileShellModel

/// Behavior tests for ``MobileOnboardingStore`` using isolated defaults suites.
@Suite struct MobileOnboardingStoreTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "MobileOnboardingStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func freshStoreHasNoCompletedMilestones() {
        let store = MobileOnboardingStore(defaults: makeDefaults())

        #expect(!store.hasSeenWelcome)
        #expect(!store.hasCompletedConnect)
        #expect(!store.hasPrimedNotifications)
    }

    @Test func markingWelcomePersistsOnlyWelcome() {
        let defaults = makeDefaults()
        let store = MobileOnboardingStore(defaults: defaults)

        store.markWelcomeSeen()

        #expect(store.hasSeenWelcome)
        #expect(!store.hasCompletedConnect)
        #expect(!store.hasPrimedNotifications)
        #expect(defaults.bool(forKey: MobileOnboardingStore.welcomeSeenKey))
        #expect(!defaults.bool(forKey: MobileOnboardingStore.connectCompletedKey))
        #expect(!defaults.bool(forKey: MobileOnboardingStore.notificationsPrimedKey))
    }

    @Test func markingConnectPersistsOnlyConnect() {
        let defaults = makeDefaults()
        let store = MobileOnboardingStore(defaults: defaults)

        store.markConnectCompleted()

        #expect(!store.hasSeenWelcome)
        #expect(store.hasCompletedConnect)
        #expect(!store.hasPrimedNotifications)
        #expect(!defaults.bool(forKey: MobileOnboardingStore.welcomeSeenKey))
        #expect(defaults.bool(forKey: MobileOnboardingStore.connectCompletedKey))
        #expect(!defaults.bool(forKey: MobileOnboardingStore.notificationsPrimedKey))
    }

    @Test func markingNotificationsPersistsOnlyPrimer() {
        let defaults = makeDefaults()
        let store = MobileOnboardingStore(defaults: defaults)

        store.markNotificationsPrimed()

        #expect(!store.hasSeenWelcome)
        #expect(!store.hasCompletedConnect)
        #expect(store.hasPrimedNotifications)
        #expect(!defaults.bool(forKey: MobileOnboardingStore.welcomeSeenKey))
        #expect(!defaults.bool(forKey: MobileOnboardingStore.connectCompletedKey))
        #expect(defaults.bool(forKey: MobileOnboardingStore.notificationsPrimedKey))
    }

    @Test func legacySeenPromotesEveryMilestone() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: MobileOnboardingStore.legacySeenKey)
        let store = MobileOnboardingStore(defaults: defaults)

        #expect(store.hasSeenWelcome)
        #expect(store.hasCompletedConnect)
        #expect(store.hasPrimedNotifications)

        store.markWelcomeSeen()
        store.markConnectCompleted()
        store.markNotificationsPrimed()

        #expect(store.hasSeenWelcome)
        #expect(store.hasCompletedConnect)
        #expect(store.hasPrimedNotifications)
    }

    @Test func forceSeenReportsCompleteWithoutWriting() {
        let defaults = makeDefaults()
        let store = MobileOnboardingStore(defaults: defaults, forceSeen: true)

        #expect(store.hasSeenWelcome)
        #expect(store.hasCompletedConnect)
        #expect(store.hasPrimedNotifications)

        store.markWelcomeSeen()
        store.markConnectCompleted()
        store.markNotificationsPrimed()

        #expect(!defaults.bool(forKey: MobileOnboardingStore.welcomeSeenKey))
        #expect(!defaults.bool(forKey: MobileOnboardingStore.connectCompletedKey))
        #expect(!defaults.bool(forKey: MobileOnboardingStore.notificationsPrimedKey))
        #expect(!defaults.bool(forKey: MobileOnboardingStore.legacySeenKey))
    }
}
