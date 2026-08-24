import Foundation
import Testing

@testable import CmuxMobileShellModel

/// Behavior tests for ``MobileOnboardingStore`` using isolated defaults suites.
@MainActor
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

    @Test func pushMilestonePersistsAcrossStoreInstances() {
        let defaults = makeDefaults()
        let store = MobileOnboardingStore(defaults: defaults)
        store.markReadyToConnect()
        store.markReadyForPush()

        #expect(store.progress == .push)
        #expect(MobileOnboardingStore(defaults: defaults).progress == .push)
    }

    @Test func completionPersistsAcrossStoreInstances() {
        let defaults = makeDefaults()
        MobileOnboardingStore(defaults: defaults).markComplete()

        #expect(MobileOnboardingStore(defaults: defaults).progress == .complete)
    }

    @Test func completedLegacyToursDoNotSuppressThisDesign() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "dev.cmux.mobile.onboarding.seen.v1")
        defaults.set(
            "complete",
            forKey: "dev.cmux.mobile.onboarding.redesign.progress.v1"
        )

        #expect(MobileOnboardingStore(defaults: defaults).progress == .welcome)
    }

    @Test func progressPersistsIndependentlyFromLegacyKeys() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "dev.cmux.mobile.onboarding.seen.v1")
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
        store.markReadyForPush()
        store.markComplete()

        #expect(defaults.string(forKey: MobileOnboardingStore.progressKey) == nil)
    }

    @Test func persistedProgressIgnoresForceCompleteBypass() {
        let defaults = makeDefaults()
        defaults.set(
            MobileOnboardingProgress.connect.rawValue,
            forKey: MobileOnboardingStore.progressKey
        )
        let store = MobileOnboardingStore(defaults: defaults, forceComplete: true)

        #expect(store.progress == .complete)
        #expect(store.persistedProgress == .connect)

        defaults.removeObject(forKey: MobileOnboardingStore.progressKey)
        #expect(store.persistedProgress == .welcome)
    }
}
