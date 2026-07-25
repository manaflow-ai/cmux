/// Preserves one physical key's owner from press through repeats and release.
///
/// AppKit can change its text-input decision while a key remains held, for
/// example when an input method or keyboard layout changes. Physical repeat
/// and release events must still follow the owner chosen for the first event
/// observed in that key lifecycle.
public struct TerminalKeyInputLifecycleTracker: Sendable {
    private enum PhysicalKeyOwner: Sendable {
        case appKit
        case terminal
    }

    private var owners: [UInt16: PhysicalKeyOwner] = [:]

    /// Creates an empty physical-key lifecycle tracker.
    public init() {}

    /// Resolves actions for a key-down without changing ownership on repeats.
    ///
    /// A repeat whose press belongs to AppKit may still deliver text committed
    /// from an existing preedit, but it cannot introduce an orphaned physical
    /// key event into the terminal.
    public mutating func actions(
        for plan: TerminalKeyInputPlan,
        keyCode: UInt16,
        isRepeat: Bool
    ) -> [TerminalKeyInputAction] {
        let plannedOwner: PhysicalKeyOwner =
            plan.forwardsPhysicalKey ? .terminal : .appKit
        let owner: PhysicalKeyOwner

        if isRepeat, let existingOwner = owners[keyCode] {
            owner = existingOwner
        } else {
            owner = plannedOwner
            owners[keyCode] = plannedOwner
        }

        guard isRepeat, owner == .appKit else {
            return plan.actions
        }
        return plan.actions.filter { action in
            guard case .sendKey = action else { return true }
            return false
        }
    }

    /// Clears a completed lifecycle and reports whether the terminal owns its release.
    ///
    /// An unmatched release is forwarded to preserve the native fallback used
    /// when focus changes after the operating system has delivered the press.
    public mutating func shouldForwardKeyUp(keyCode: UInt16) -> Bool {
        owners.removeValue(forKey: keyCode) != .appKit
    }

    /// Clears all key lifecycles after responder ownership changes.
    public mutating func reset() {
        owners.removeAll(keepingCapacity: true)
    }
}
