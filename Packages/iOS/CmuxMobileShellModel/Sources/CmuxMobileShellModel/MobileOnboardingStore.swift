public import Foundation
import Observation

/// Persists the durable milestone reached in first-run onboarding.
///
/// The flow presents a welcome pitch, then sign-in when needed, then computer
/// connection, then the push-notification offer. Persisting each milestone
/// means a person who leaves mid-flow resumes at the remaining step instead of
/// replaying what they already saw. Every step is individually skippable.
///
/// The backing `UserDefaults` is injected so the store is testable without
/// touching `.standard`; the app constructs it at the composition root with
/// `UserDefaults.standard`.
///
/// `forceComplete` lets automated launch paths bypass onboarding without
/// writing through to the real install's progress.
///
/// ```swift
/// let store = MobileOnboardingStore(defaults: .standard)
/// if store.progress == .welcome { /* present the welcome pitch */ }
/// store.markReadyToConnect()
/// ```
@MainActor
@Observable
public final class MobileOnboardingStore {
    /// The defaults key under which this onboarding design's milestone is stored.
    ///
    /// This key is intentionally independent from prior onboarding designs so
    /// completing an older tour does not suppress this one.
    public static let progressKey = "dev.cmux.mobile.onboarding.v3.progress.v1"

    // UserDefaults is Apple-documented thread-safe; OK to hold nonisolated.
    private nonisolated(unsafe) let defaults: UserDefaults
    private let forceComplete: Bool

    /// The durable milestone at which onboarding should resume.
    public private(set) var progress: MobileOnboardingProgress

    /// Create a store backed by the given defaults.
    /// - Parameters:
    ///   - defaults: The persistence store for onboarding progress. Inject a
    ///     suite-scoped `UserDefaults` in tests.
    ///   - forceComplete: When `true`, ``progress`` always returns
    ///     ``MobileOnboardingProgress/complete`` and writes are ignored.
    public init(defaults: UserDefaults, forceComplete: Bool = false) {
        self.defaults = defaults
        self.forceComplete = forceComplete
        if forceComplete {
            self.progress = .complete
        } else if let rawValue = defaults.string(forKey: Self.progressKey),
                  let progress = MobileOnboardingProgress(rawValue: rawValue) {
            self.progress = progress
        } else {
            self.progress = .welcome
        }
    }

    /// Persist that the welcome pitch is complete and connection setup remains.
    public func markReadyToConnect() {
        setProgress(.connect)
    }

    /// Persist that connection setup finished or was skipped and the
    /// push-notification offer remains.
    public func markReadyForPush() {
        setProgress(.push)
    }

    /// Persist that onboarding finished (steps may have been skipped).
    public func markComplete() {
        setProgress(.complete)
    }

    private func setProgress(_ progress: MobileOnboardingProgress) {
        guard !forceComplete else { return }
        defaults.set(progress.rawValue, forKey: Self.progressKey)
        self.progress = progress
    }
}
