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
        var unshiftedCodepoint: UInt32?
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
            unshiftedCodepoint: nil
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
            return nonPhysicalActions
        case .terminal:
            return nonPhysicalActions + lifecycle.terminalActions
        }
    }

    /// Preserves the first physical-layout identity through repeats.
    public mutating func unshiftedCodepoint(
        forKeyDown keyCode: UInt16,
        resolvedCodepoint: UInt32,
        isRepeat: Bool
    ) -> UInt32 {
        if isRepeat,
           let codepoint = lifecycles[keyCode]?.unshiftedCodepoint {
            return codepoint
        }

        guard var lifecycle = lifecycles[keyCode] else {
            lifecycles[keyCode] = PhysicalKeyLifecycle(
                owner: .terminal,
                terminalActions: [],
                unshiftedCodepoint: resolvedCodepoint
            )
            return resolvedCodepoint
        }

        lifecycle.unshiftedCodepoint = resolvedCodepoint
        lifecycles[keyCode] = lifecycle
        return resolvedCodepoint
    }

    /// Clears a completed lifecycle and returns its release metadata.
    ///
    /// An unmatched release is forwarded to preserve the native fallback used
    /// when focus changes after the operating system has delivered the press.
    public mutating func release(forKeyUp keyCode: UInt16) -> TerminalKeyInputRelease {
        guard let lifecycle = lifecycles.removeValue(forKey: keyCode) else {
            return TerminalKeyInputRelease(
                forwardsPhysicalKey: true,
                unshiftedCodepoint: nil
            )
        }
        return TerminalKeyInputRelease(
            forwardsPhysicalKey: lifecycle.owner == .terminal,
            unshiftedCodepoint: lifecycle.unshiftedCodepoint
        )
    }

    /// Clears all key lifecycles after responder ownership changes.
    public mutating func reset() {
        lifecycles.removeAll(keepingCapacity: true)
    }
}

private extension TerminalKeyInputAction {
    var isPhysicalKey: Bool {
        guard case .sendKey = self else { return false }
        return true
    }

    var forwardsPhysicalKey: Bool {
        guard case .sendKey(_, composing: false) = self else { return false }
        return true
    }
}
