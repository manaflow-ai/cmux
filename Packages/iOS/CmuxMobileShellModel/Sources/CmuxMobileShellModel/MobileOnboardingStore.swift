public import Foundation
import Observation

/// Persists the durable milestone reached in first-run onboarding.
///
/// The flow presents a short product tour, then signs in if needed, and finally
/// starts same-account computer discovery. Persisting the transition to
/// ``MobileOnboardingProgress/connect`` means a person who leaves during sign-in
/// or connection resumes at the remaining prerequisite instead of replaying the
/// product tour. QR pairing remains an explicit fallback.
///
/// The backing `UserDefaults` is injected so the store is testable without
/// touching `.standard`; the app constructs it at the composition root with
/// `UserDefaults.standard`.
///
/// `forceComplete` lets automated launch paths bypass onboarding without writing
/// through to the real install's progress.
///
/// ```swift
/// let store = MobileOnboardingStore(defaults: .standard)
/// if store.progress == .welcome { /* present the product tour */ }
/// store.markReadyToConnect()
/// ```
@MainActor
@Observable
public final class MobileOnboardingStore {
    /// The defaults key under which the current milestone is stored.
    public static let progressKey = "dev.cmux.mobile.onboarding.progress.v2"

    /// The Boolean key used by the original onboarding implementation.
    ///
    /// A completed legacy tour maps to ``MobileOnboardingProgress/complete`` so
    /// the redesign does not interrupt people who already use the app.
    public static let legacySeenKey = "dev.cmux.mobile.onboarding.seen.v1"

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
        } else if defaults.bool(forKey: Self.legacySeenKey) {
            self.progress = .complete
        } else {
            self.progress = .welcome
        }
    }

    /// Persist that the product demonstration is complete and setup remains.
    public func markReadyToConnect() {
        setProgress(.connect)
    }

    /// Persist that onboarding was skipped or computer activation succeeded.
    public func markComplete() {
        setProgress(.complete)
    }

    private func setProgress(_ progress: MobileOnboardingProgress) {
        guard !forceComplete else { return }
        defaults.set(progress.rawValue, forKey: Self.progressKey)
        self.progress = progress
    }
}
