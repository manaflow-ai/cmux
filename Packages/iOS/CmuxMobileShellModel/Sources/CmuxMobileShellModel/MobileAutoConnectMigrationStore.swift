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
    /// The versioned resolution key for this introduction.
    public static let resolutionKey = "dev.cmux.mobile.autoConnectIntroduction.v1"

    // UserDefaults is Apple-documented thread-safe; OK to hold nonisolated.
    private nonisolated(unsafe) let defaults: UserDefaults
    private let persistedResolutionKey: String

    /// The immutable eligibility snapshot or its later acknowledgement.
    public private(set) var resolution: MobileAutoConnectMigrationResolution

    /// Creates a migration store and snapshots unresolved eligibility once.
    ///
    /// - Parameters:
    ///   - defaults: The persistence source. The app injects `.standard`; tests
    ///     inject a suite-scoped instance.
    ///   - resolutionKey: The versioned resolution key. DEBUG UI evidence uses
    ///     a per-run key so it cannot affect the production resolution.
    ///   - eligibilityOverride: An optional deterministic eligibility used only
    ///     by isolated DEBUG evidence. `nil` reads the production prerequisite
    ///     keys directly.
    public init(
        defaults: UserDefaults,
        resolutionKey: String = MobileAutoConnectMigrationStore.resolutionKey,
        eligibilityOverride: Bool? = nil
    ) {
        self.defaults = defaults
        self.persistedResolutionKey = resolutionKey

        if let persistedValue = defaults.object(forKey: resolutionKey) {
            if let rawValue = persistedValue as? String,
               let persisted = MobileAutoConnectMigrationResolution(rawValue: rawValue) {
                self.resolution = persisted
            } else {
                self.resolution = .ineligible
                defaults.set(
                    MobileAutoConnectMigrationResolution.ineligible.rawValue,
                    forKey: resolutionKey
                )
            }
            return
        }

        let isEligible = eligibilityOverride ?? (
            defaults.string(forKey: MobileOnboardingStore.progressKey)
                == MobileOnboardingProgress.complete.rawValue
                && defaults.object(forKey: MobileConnectionMethodStore.methodKey) == nil
        )
        let snapshot: MobileAutoConnectMigrationResolution = isEligible ? .pending : .ineligible
        self.resolution = snapshot
        defaults.set(snapshot.rawValue, forKey: resolutionKey)
    }

    /// Permanently resolves a pending introduction after explicit dismissal.
    public func acknowledge() {
        guard resolution == .pending else { return }
        defaults.set(
            MobileAutoConnectMigrationResolution.acknowledged.rawValue,
            forKey: persistedResolutionKey
        )
        resolution = .acknowledged
    }
}
