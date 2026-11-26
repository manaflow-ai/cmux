import Foundation
import Testing

@testable import CmuxMobileShellModel

/// Behavior coverage for the one-time Auto-Connect migration snapshot.
@MainActor
@Suite struct MobileAutoConnectMigrationStoreTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "MobileAutoConnectMigrationStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func eligibleUpgradeSnapshotsPendingWithoutChoosingAMethod() {
        let defaults = makeDefaults()
        defaults.set(
            MobileOnboardingProgress.complete.rawValue,
            forKey: MobileOnboardingStore.progressKey
        )

        let store = MobileAutoConnectMigrationStore(defaults: defaults)

        #expect(store.resolution == .pending)
        #expect(
            defaults.string(forKey: MobileAutoConnectMigrationStore.resolutionKey)
                == MobileAutoConnectMigrationResolution.pending.rawValue
        )
        #expect(defaults.object(forKey: MobileConnectionMethodStore.methodKey) == nil)
    }

    @Test(arguments: [nil, "welcome", "connect", "unknown"] as [String?])
    func incompleteOrMissingRawOnboardingIsIneligible(_ rawProgress: String?) {
        let defaults = makeDefaults()
        if let rawProgress {
            defaults.set(rawProgress, forKey: MobileOnboardingStore.progressKey)
        }

        let store = MobileAutoConnectMigrationStore(defaults: defaults)

        #expect(store.resolution == .ineligible)
        #expect(
            defaults.string(forKey: MobileAutoConnectMigrationStore.resolutionKey)
                == MobileAutoConnectMigrationResolution.ineligible.rawValue
        )
    }

    @Test(arguments: ["automatic", "tailscale", "unknown"])
    func completedUpgradeRemainsEligibleAfterAConnectionChoice(_ rawMethod: String) {
        let defaults = makeDefaults()
        defaults.set(
            MobileOnboardingProgress.complete.rawValue,
            forKey: MobileOnboardingStore.progressKey
        )
        defaults.set(rawMethod, forKey: MobileConnectionMethodStore.methodKey)

        #expect(MobileAutoConnectMigrationStore(defaults: defaults).resolution == .pending)
    }

    @Test(arguments: MobileAutoConnectMigrationResolution.allCases)
    func priorIntroductionResolutionDoesNotSuppressMacVersionNotice(
        _ priorResolution: MobileAutoConnectMigrationResolution
    ) {
        let defaults = makeDefaults()
        defaults.set(
            priorResolution.rawValue,
            forKey: MobileAutoConnectMigrationStore.legacyResolutionKey
        )
        defaults.set(
            MobileOnboardingProgress.complete.rawValue,
            forKey: MobileOnboardingStore.progressKey
        )

        #expect(MobileAutoConnectMigrationStore(defaults: defaults).resolution == .pending)
    }

    @Test(arguments: MobileAutoConnectMigrationResolution.allCases)
    func existingResolutionWinsWithoutRecomputing(
        _ resolution: MobileAutoConnectMigrationResolution
    ) {
        let defaults = makeDefaults()
        defaults.set(resolution.rawValue, forKey: MobileAutoConnectMigrationStore.resolutionKey)
        defaults.set(
            MobileOnboardingProgress.complete.rawValue,
            forKey: MobileOnboardingStore.progressKey
        )

        #expect(MobileAutoConnectMigrationStore(defaults: defaults).resolution == resolution)
    }

    @Test func invalidExistingResolutionFailsClosed() {
        let defaults = makeDefaults()
        defaults.set("future-state", forKey: MobileAutoConnectMigrationStore.resolutionKey)
        defaults.set(
            MobileOnboardingProgress.complete.rawValue,
            forKey: MobileOnboardingStore.progressKey
        )

        let store = MobileAutoConnectMigrationStore(defaults: defaults)

        #expect(store.resolution == .ineligible)
        #expect(
            defaults.string(forKey: MobileAutoConnectMigrationStore.resolutionKey)
                == MobileAutoConnectMigrationResolution.ineligible.rawValue
        )
    }

    @Test func pendingSurvivesTerminationUntilAcknowledged() {
        let defaults = makeDefaults()
        defaults.set(
            MobileOnboardingProgress.complete.rawValue,
            forKey: MobileOnboardingStore.progressKey
        )

        #expect(MobileAutoConnectMigrationStore(defaults: defaults).resolution == .pending)
        #expect(MobileAutoConnectMigrationStore(defaults: defaults).resolution == .pending)
    }

    @Test(arguments: ["automatic", "tailscale", "unknown"])
    func acknowledgementPersistsWithoutChangingSavedConnectionMethod(_ rawMethod: String) {
        let defaults = makeDefaults()
        defaults.set(
            MobileOnboardingProgress.complete.rawValue,
            forKey: MobileOnboardingStore.progressKey
        )
        defaults.set(rawMethod, forKey: MobileConnectionMethodStore.methodKey)
        let store = MobileAutoConnectMigrationStore(defaults: defaults)

        store.acknowledge()

        #expect(store.resolution == .acknowledged)
        #expect(
            MobileAutoConnectMigrationStore(defaults: defaults).resolution == .acknowledged
        )
        #expect(defaults.string(forKey: MobileConnectionMethodStore.methodKey) == rawMethod)
    }

    @Test func acknowledgementCannotPromoteAnIneligibleInstall() {
        let defaults = makeDefaults()
        let store = MobileAutoConnectMigrationStore(defaults: defaults)

        store.acknowledge()

        #expect(store.resolution == .ineligible)
    }

    @Test func forceCompleteOnboardingDoesNotQualifyWithoutRawCompletion() {
        let defaults = makeDefaults()
        let onboardingStore = MobileOnboardingStore(defaults: defaults, forceComplete: true)
        #expect(onboardingStore.progress == .complete)

        #expect(MobileAutoConnectMigrationStore(defaults: defaults).resolution == .ineligible)
    }

    @Test func pendingSnapshotNeverRecomputesAfterAConnectionChoiceAppears() {
        let defaults = makeDefaults()
        defaults.set(
            MobileOnboardingProgress.complete.rawValue,
            forKey: MobileOnboardingStore.progressKey
        )
        #expect(MobileAutoConnectMigrationStore(defaults: defaults).resolution == .pending)

        defaults.set(
            MobileConnectionMethod.tailscale.rawValue,
            forKey: MobileConnectionMethodStore.methodKey
        )

        #expect(MobileAutoConnectMigrationStore(defaults: defaults).resolution == .pending)
    }

    @Test func ineligibleSnapshotNeverRecomputesAfterOnboardingCompletes() {
        let defaults = makeDefaults()
        #expect(MobileAutoConnectMigrationStore(defaults: defaults).resolution == .ineligible)

        defaults.set(
            MobileOnboardingProgress.complete.rawValue,
            forKey: MobileOnboardingStore.progressKey
        )

        #expect(MobileAutoConnectMigrationStore(defaults: defaults).resolution == .ineligible)
    }

    @Test func aDifferentVersionedResolutionKeyTakesANewSnapshot() {
        let defaults = makeDefaults()
        defaults.set(
            MobileAutoConnectMigrationResolution.acknowledged.rawValue,
            forKey: "dev.cmux.mobile.autoConnectIntroduction.v0"
        )
        defaults.set(
            MobileOnboardingProgress.complete.rawValue,
            forKey: MobileOnboardingStore.progressKey
        )

        let store = MobileAutoConnectMigrationStore(defaults: defaults)

        #expect(store.resolution == .pending)
    }
}
