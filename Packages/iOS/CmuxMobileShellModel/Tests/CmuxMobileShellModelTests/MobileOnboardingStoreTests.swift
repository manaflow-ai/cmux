import Foundation
import Testing

@testable import CmuxMobileShellModel

/// Behavior tests for ``MobileOnboardingStore`` using a suite-scoped
/// `UserDefaults` so they never touch `UserDefaults.standard`.
@Suite struct MobileOnboardingStoreTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "MobileOnboardingStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func startsUnseenAndPersistsSeen() {
        let defaults = makeDefaults()
        let store = MobileOnboardingStore(defaults: defaults)
        #expect(!store.hasSeenOnboarding)

        store.markSeen()
        #expect(store.hasSeenOnboarding)
        #expect(defaults.bool(forKey: MobileOnboardingStore.defaultsKey))
    }

    @Test func readsAPreviouslyPersistedSeenFlag() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: MobileOnboardingStore.defaultsKey)
        let store = MobileOnboardingStore(defaults: defaults)
        #expect(store.hasSeenOnboarding)
    }

    /// `forceSeen` reports seen without reading or writing the backing defaults,
    /// so the UI-test / dogfood bypass never wedges behind onboarding and never
    /// pollutes the real install's persisted flag.
    @Test func forceSeenReportsSeenWithoutPersisting() {
        let defaults = makeDefaults()
        let store = MobileOnboardingStore(defaults: defaults, forceSeen: true)
        #expect(store.hasSeenOnboarding)

        store.markSeen()
        #expect(!defaults.bool(forKey: MobileOnboardingStore.defaultsKey))
    }
}
