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

    @Test func startsAtWelcomeAndResumesConnectionSetup() {
        let defaults = makeDefaults()
        let store = MobileOnboardingStore(defaults: defaults)
        #expect(store.progress == .welcome)

        store.markReadyToConnect()

        #expect(store.progress == .connect)
        #expect(MobileOnboardingStore(defaults: defaults).progress == .connect)
    }

    @Test func completionPersistsAcrossStoreInstances() {
        let defaults = makeDefaults()
        MobileOnboardingStore(defaults: defaults).markComplete()

        #expect(MobileOnboardingStore(defaults: defaults).progress == .complete)
    }

    @Test func completedLegacyTourDoesNotResurfaceRedesign() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: MobileOnboardingStore.legacySeenKey)

        #expect(MobileOnboardingStore(defaults: defaults).progress == .complete)
    }

    @Test func currentProgressWinsOverLegacyFlag() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: MobileOnboardingStore.legacySeenKey)
        defaults.set(
            MobileOnboardingProgress.connect.rawValue,
            forKey: MobileOnboardingStore.progressKey
        )

        #expect(MobileOnboardingStore(defaults: defaults).progress == .connect)
    }

    @Test func forceCompleteBypassesWithoutPersisting() {
        let defaults = makeDefaults()
        let store = MobileOnboardingStore(defaults: defaults, forceComplete: true)
        #expect(store.progress == .complete)

        store.markReadyToConnect()
        store.markComplete()

        #expect(defaults.string(forKey: MobileOnboardingStore.progressKey) == nil)
    }
}
