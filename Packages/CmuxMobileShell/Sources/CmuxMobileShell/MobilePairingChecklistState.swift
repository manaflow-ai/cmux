import CmuxMobileShellModel

/// Owns the foreground-only checklist projection for one pairing attempt.
struct MobilePairingChecklistState {
    private(set) var checklist: MobilePairingChecklist?
    private var isForegroundAttempt = false
    private var reachedMac = false

    mutating func setForegroundAttempt(_ value: Bool) {
        isForegroundAttempt = value
    }

    mutating func beginValidationAttempt(hasMethod: Bool) {
        reachedMac = false
        checklist = hasMethod && isForegroundAttempt ? .connecting : nil
    }

    mutating func markReachedMac() {
        reachedMac = true
    }

    mutating func resolveFailure(
        _ category: MobilePairingFailureCategory,
        hasInstrumentedAttempt: Bool
    ) {
        guard isForegroundAttempt, hasInstrumentedAttempt else { return }
        checklist = .resolving(category, reachedMac: reachedMac)
    }

    mutating func markConnected() {
        guard isForegroundAttempt else { return }
        checklist = .connected
    }

    mutating func clearChecklist() {
        checklist = nil
    }
}
