public import CoreGraphics
public import Foundation

/// Pure decision policy for the session-snapshot persist/autosave lifecycle.
///
/// Faithful lift of the `nonisolated static` decision-helper family from the
/// `AppDelegate` session block: `shouldPersistSnapshotOnWindowUnregister`,
/// `shouldSaveSessionSnapshotAfterMainWindowRegistration`,
/// `shouldSkipSessionSaveDuringRestore`, `shouldRunSessionAutosaveTick`,
/// `shouldSaveSessionSnapshotOnApplicationResign`,
/// `shouldSaveSessionSnapshotOnRestoreCompletion`,
/// `shouldWriteSessionSnapshotSynchronously`,
/// `shouldSkipSessionAutosaveForUnchangedFingerprint`, plus the `hashFrame`
/// quantizer the autosave fingerprint feeds each window frame through. Every
/// branch is unchanged; only the receiver moved from the god file into this
/// package value.
///
/// Isolation: a stateless `Sendable` struct, not an actor and not a static-only
/// namespace. The lone tunable, ``maximumAutosaveSkippableInterval``, is
/// constructor-injected so the 60-second skip window lives at the composition
/// root and tests can drive it; the app holds one shared instance and forwards.
/// The methods are pure transforms over the booleans, fingerprints, dates, and
/// the rect handed to each call, so there is no mutable state to protect.
public struct SessionPersistenceDecisionPolicy: Sendable {
    /// The longest interval an unchanged autosave fingerprint suppresses a
    /// write before one is forced anyway. Legacy
    /// `shouldSkipSessionAutosaveForUnchangedFingerprint`'s
    /// `maximumAutosaveSkippableInterval` default (60 seconds).
    public let maximumAutosaveSkippableInterval: TimeInterval

    /// Creates a decision policy.
    ///
    /// - Parameter maximumAutosaveSkippableInterval: the longest interval an
    ///   unchanged autosave fingerprint suppresses a write (legacy default 60).
    public init(maximumAutosaveSkippableInterval: TimeInterval = 60) {
        self.maximumAutosaveSkippableInterval = maximumAutosaveSkippableInterval
    }

    /// Whether a window unregistering should persist the session snapshot first.
    /// Skipped during app termination, which already persists on its own path.
    public func shouldPersistSnapshotOnWindowUnregister(isTerminatingApp: Bool) -> Bool {
        !isTerminatingApp
    }

    /// Whether registering a main window should trigger a session save. Skipped
    /// while terminating and while a startup or in-flight restore is applying,
    /// so a restore's own window registration does not clobber the snapshot.
    public func shouldSaveSessionSnapshotAfterMainWindowRegistration(
        isTerminatingApp: Bool,
        didApplyStartupSessionRestore: Bool,
        isApplyingSessionRestore: Bool
    ) -> Bool {
        !isTerminatingApp && !didApplyStartupSessionRestore && !isApplyingSessionRestore
    }

    /// Whether a non-scrollback save should be skipped because a restore is in
    /// progress. A scrollback save (`includeScrollback == true`) is never
    /// skipped, so a terminating restore still captures scrollback.
    public func shouldSkipSessionSaveDuringRestore(
        isApplyingSessionRestore: Bool,
        includeScrollback: Bool
    ) -> Bool {
        isApplyingSessionRestore && !includeScrollback
    }

    /// Whether the autosave timer should run a tick. Suppressed during app
    /// termination, which persists session state on its own path.
    public func shouldRunSessionAutosaveTick(isTerminatingApp: Bool) -> Bool {
        !isTerminatingApp
    }

    /// Whether resigning active should persist the session snapshot. Always
    /// false: app switching stays cheap. The autosave timer, window/session
    /// lifecycle, power-off, update relaunch, and termination paths still
    /// persist session state.
    public func shouldSaveSessionSnapshotOnApplicationResign(isTerminatingApp _: Bool) -> Bool {
        false
    }

    /// Whether completing a restore should immediately save a fresh snapshot.
    /// A manual reopen (the user reopening a closed session) keeps the existing
    /// on-disk snapshot, so it does not re-save.
    public func shouldSaveSessionSnapshotOnRestoreCompletion(isManualReopen: Bool) -> Bool {
        !isManualReopen
    }

    /// Whether a save must be written synchronously rather than queued. Only the
    /// terminating scrollback save writes synchronously, so the snapshot lands
    /// before the process exits.
    public func shouldWriteSessionSnapshotSynchronously(
        isTerminatingApp: Bool,
        includeScrollback: Bool
    ) -> Bool {
        isTerminatingApp && includeScrollback
    }

    /// Whether an autosave write should be skipped because the fingerprint is
    /// unchanged and the last persist is recent. Never skips while terminating,
    /// for scrollback saves, when either fingerprint is absent, when the
    /// fingerprints differ, or once ``maximumAutosaveSkippableInterval`` has
    /// elapsed since the last persist.
    public func shouldSkipSessionAutosaveForUnchangedFingerprint(
        isTerminatingApp: Bool,
        includeScrollback: Bool,
        previousFingerprint: Int?,
        currentFingerprint: Int?,
        lastPersistedAt: Date,
        now: Date
    ) -> Bool {
        guard !isTerminatingApp,
              !includeScrollback,
              let previousFingerprint,
              let currentFingerprint,
              previousFingerprint == currentFingerprint else {
            return false
        }

        return now.timeIntervalSince(lastPersistedAt) < maximumAutosaveSkippableInterval
    }

    /// Folds a window frame into the autosave fingerprint hasher.
    ///
    /// Standardizes the rect, quantizes each component to half-point precision
    /// (`Int((value * 2).rounded())`) so sub-half-point jitter does not change
    /// the fingerprint, and combines the four quantized values in order.
    /// Byte-identical to the legacy `AppDelegate.hashFrame(_:into:)`.
    public func hashFrame(_ frame: CGRect, into hasher: inout Hasher) {
        let standardized = frame.standardized
        let quantized = [
            standardized.origin.x,
            standardized.origin.y,
            standardized.size.width,
            standardized.size.height,
        ].map { Int(($0 * 2).rounded()) }
        quantized.forEach { hasher.combine($0) }
    }
}
