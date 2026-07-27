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

    private struct PhysicalKeyLifecycle: Sendable {
        let owner: PhysicalKeyOwner
        let terminalActions: [TerminalKeyInputAction]
        var physicalIdentity: TerminalKeyInputPhysicalIdentity?
    }

    private var lifecycles: [UInt16: PhysicalKeyLifecycle] = [:]

    /// Creates an empty physical-key lifecycle tracker.
    public init() {}

    /// Resolves actions for a key-down without changing ownership or physical
    /// meaning on repeats.
    ///
    /// A repeat whose press belongs to AppKit may still deliver text committed
    /// from an existing preedit, but it cannot introduce an orphaned physical
    /// key event into the terminal. A repeat whose press belongs to the terminal
    /// keeps the original physical action even if AppKit changes its decision.
    public mutating func actions(
        for plan: TerminalKeyInputPlan,
        keyCode: UInt16,
        isRepeat: Bool
    ) -> [TerminalKeyInputAction] {
        let plannedOwner: PhysicalKeyOwner =
            plan.forwardsPhysicalKey ? .terminal : .appKit
        let plannedLifecycle = PhysicalKeyLifecycle(
            owner: plannedOwner,
            terminalActions: plan.actions.filter(\.forwardsPhysicalKey),
            physicalIdentity: nil
        )
        let lifecycle: PhysicalKeyLifecycle

        if isRepeat, let existingLifecycle = lifecycles[keyCode] {
            lifecycle = existingLifecycle
        } else {
            lifecycle = plannedLifecycle
            lifecycles[keyCode] = plannedLifecycle
        }

        guard isRepeat else { return plan.actions }

        let nonPhysicalActions = plan.actions.filter { !$0.isPhysicalKey }
        switch lifecycle.owner {
        case .appKit:
            return plan.actions.compactMap(\.withoutPhysicalOwnership)
        case .terminal:
            return nonPhysicalActions + lifecycle.terminalActions
        }
    }

    /// Preserves the initial text translation metadata through repeats.
    public mutating func physicalIdentity(
        forKeyDown keyCode: UInt16,
        resolvedIdentity: TerminalKeyInputPhysicalIdentity,
        isRepeat: Bool
    ) -> TerminalKeyInputPhysicalIdentity {
        if isRepeat,
           let physicalIdentity = lifecycles[keyCode]?.physicalIdentity {
            return physicalIdentity
        }

        guard var lifecycle = lifecycles[keyCode] else {
            lifecycles[keyCode] = PhysicalKeyLifecycle(
                owner: .terminal,
                terminalActions: [],
                physicalIdentity: resolvedIdentity
            )
            return resolvedIdentity
        }

        lifecycle.physicalIdentity = resolvedIdentity
        lifecycles[keyCode] = lifecycle
        return resolvedIdentity
    }

    /// Clears a completed lifecycle and returns its release metadata.
    ///
    /// An unmatched release is forwarded to preserve the native fallback used
    /// when focus changes after the operating system has delivered the press.
    public mutating func release(forKeyUp keyCode: UInt16) -> TerminalKeyInputRelease {
        guard let lifecycle = lifecycles.removeValue(forKey: keyCode) else {
            return TerminalKeyInputRelease(
                forwardsPhysicalKey: true,
                physicalIdentity: nil
            )
        }
        return TerminalKeyInputRelease(
            forwardsPhysicalKey: lifecycle.owner == .terminal,
            physicalIdentity: lifecycle.physicalIdentity
        )
    }

    /// Clears all key lifecycles after responder ownership changes.
    public mutating func reset() {
        lifecycles.removeAll(keepingCapacity: true)
    }
}
