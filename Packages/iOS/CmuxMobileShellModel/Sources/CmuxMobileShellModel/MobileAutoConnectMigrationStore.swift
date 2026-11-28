public import Foundation
import Observation

/// Snapshots and persists eligibility for the one-time Auto-Connect introduction.
///
/// Construction performs a bounded synchronous read of the versioned resolution,
/// raw onboarding progress, and connection-method keys. When no resolution exists,
/// it immediately persists either ``MobileAutoConnectMigrationResolution/pending``
/// or ``MobileAutoConnectMigrationResolution/ineligible``. Later writes in the
/// same launch can therefore never change eligibility.
@MainActor
@Observable
public final class MobileAutoConnectMigrationStore {
    /// The prior Auto-Connect-only introduction key. Its resolution cannot
    /// suppress the newer notice because that notice adds Mac version minima.
    static let legacyResolutionKey = "dev.cmux.mobile.autoConnectIntroduction.v1"
    /// The versioned resolution key for the Mac compatibility introduction.
    public static let resolutionKey = "dev.cmux.mobile.autoConnectIntroduction.v2"

    // UserDefaults is Apple-documented thread-safe; OK to hold nonisolated.
    private nonisolated(unsafe) let defaults: UserDefaults

    /// The immutable eligibility snapshot or its later acknowledgement.
    public private(set) var resolution: MobileAutoConnectMigrationResolution

    /// Creates a migration store and snapshots unresolved eligibility once.
    ///
    /// - Parameter defaults: The persistence source. The app injects `.standard`;
    ///   tests inject a suite-scoped instance.
    public init(defaults: UserDefaults) {
        self.defaults = defaults

        if let persistedValue = defaults.object(forKey: Self.resolutionKey) {
            if let rawValue = persistedValue as? String,
               let persisted = MobileAutoConnectMigrationResolution(rawValue: rawValue) {
                self.resolution = persisted
            } else {
                self.resolution = .ineligible
                defaults.set(
                    MobileAutoConnectMigrationResolution.ineligible.rawValue,
                    forKey: Self.resolutionKey
                )
            }
            return
        }

        let isEligible = defaults.string(forKey: MobileOnboardingStore.progressKey)
            == MobileOnboardingProgress.complete.rawValue
        let snapshot: MobileAutoConnectMigrationResolution = isEligible ? .pending : .ineligible
        self.resolution = snapshot
        defaults.set(snapshot.rawValue, forKey: Self.resolutionKey)
    }

    /// Permanently resolves a pending introduction after explicit dismissal.
    public func acknowledge() {
        guard resolution == .pending else { return }
        defaults.set(
            MobileAutoConnectMigrationResolution.acknowledged.rawValue,
            forKey: Self.resolutionKey
        )
        resolution = .acknowledged
    }
}
