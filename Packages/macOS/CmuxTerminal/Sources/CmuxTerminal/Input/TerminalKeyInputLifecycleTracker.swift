/// Preserves one physical key's owner from press through repeats and release.
///
/// AppKit can change its text-input decision while a key remains held, for
/// example when an input method or keyboard layout changes. Physical repeat
/// and release events must still follow the owner chosen for the first event
/// observed in that key lifecycle.
public struct TerminalKeyInputLifecycleTracker: Sendable {
    private enum PhysicalKeyOwner: Sendable {
        case unresolved
        case appKit
        case terminal
    }

    private struct PhysicalKeyLifecycle: Sendable {
        var owner: PhysicalKeyOwner
        var physicalIdentity: TerminalKeyInputPhysicalIdentity?
        var lastEventIdentity: PhysicalKeyEventIdentity?
        var requiresTerminalRelease: Bool
    }

    private var lifecycles: [UInt16: PhysicalKeyLifecycle] = [:]

    /// Creates an empty physical-key lifecycle tracker.
    public init() {}

    /// Resolves actions for a key-down without changing ownership on repeats.
    ///
    /// A repeat whose press belongs to AppKit may still deliver text committed
    /// from an existing preedit, but it cannot introduce an orphaned physical
    /// key event into the terminal. A terminal-owned repeat uses the current
    /// AppKit semantic result while retaining terminal ownership for release.
    public mutating func actions(
        for plan: TerminalKeyInputPlan,
        keyCode: UInt16,
        isRepeat: Bool,
        eventIdentity: PhysicalKeyEventIdentity? = nil
    ) -> [TerminalKeyInputAction] {
        let plannedOwner: PhysicalKeyOwner =
            plan.forwardsPhysicalKey ? .terminal : .appKit
        var lifecycle: PhysicalKeyLifecycle

        if isRepeat, var existingLifecycle = lifecycles[keyCode] {
            if existingLifecycle.owner == .unresolved {
                existingLifecycle.owner = plannedOwner
                if plannedOwner == .terminal {
                    existingLifecycle.requiresTerminalRelease = true
                }
            }
            existingLifecycle.lastEventIdentity =
                eventIdentity ?? existingLifecycle.lastEventIdentity
            lifecycle = existingLifecycle
        } else if let eventIdentity,
                  var preparedLifecycle = lifecycles[keyCode],
                  preparedLifecycle.lastEventIdentity == eventIdentity {
            if preparedLifecycle.owner == .unresolved {
                preparedLifecycle.owner = plannedOwner
                if plannedOwner == .terminal {
                    preparedLifecycle.requiresTerminalRelease = true
                }
            }
            lifecycle = preparedLifecycle
        } else {
            lifecycle = PhysicalKeyLifecycle(
                owner: plannedOwner,
                physicalIdentity: nil,
                lastEventIdentity: eventIdentity,
                requiresTerminalRelease: plannedOwner == .terminal
            )
        }
        lifecycles[keyCode] = lifecycle

        guard isRepeat else { return plan.actions }

        switch lifecycle.owner {
        case .unresolved:
            return plan.actions
        case .appKit:
            return plan.actions.compactMap(\.withoutPhysicalOwnership)
        case .terminal:
            return plan.actions
        }
    }

    /// Resolves the stable physical identity used by a Ghostty binding probe.
    ///
    /// A probe precedes ownership. It must share identity with a later key send
    /// without making a probe-only event look terminal-owned at key-up.
    public mutating func physicalIdentityForBindingProbe(
        forKeyDown keyCode: UInt16,
        resolvedIdentity: TerminalKeyInputPhysicalIdentity,
        isRepeat: Bool,
        eventIdentity: PhysicalKeyEventIdentity
    ) -> TerminalKeyInputPhysicalIdentity {
        if isRepeat, var lifecycle = lifecycles[keyCode] {
            lifecycle.lastEventIdentity = eventIdentity
            if let physicalIdentity = lifecycle.physicalIdentity {
                lifecycles[keyCode] = lifecycle
                return physicalIdentity
            }
            lifecycle.physicalIdentity = resolvedIdentity
            lifecycles[keyCode] = lifecycle
            return resolvedIdentity
        }

        if var lifecycle = lifecycles[keyCode],
           lifecycle.lastEventIdentity == eventIdentity {
            if let physicalIdentity = lifecycle.physicalIdentity {
                return physicalIdentity
            }
            lifecycle.physicalIdentity = resolvedIdentity
            lifecycles[keyCode] = lifecycle
            return resolvedIdentity
        }

        lifecycles[keyCode] = PhysicalKeyLifecycle(
            owner: .unresolved,
            physicalIdentity: resolvedIdentity,
            lastEventIdentity: eventIdentity,
            requiresTerminalRelease: false
        )
        return resolvedIdentity
    }

    /// Records that Ghostty consumed a menu-owned binding and now requires the
    /// matching physical release, even though no terminal key-down was sent.
    public mutating func recordGhosttyMenuBindingConsumption(
        forKeyDown keyCode: UInt16,
        eventIdentity: PhysicalKeyEventIdentity
    ) {
        guard var lifecycle = lifecycles[keyCode],
              lifecycle.lastEventIdentity == eventIdentity else {
            lifecycles[keyCode] = PhysicalKeyLifecycle(
                owner: .unresolved,
                physicalIdentity: nil,
                lastEventIdentity: eventIdentity,
                requiresTerminalRelease: true
            )
            return
        }
        lifecycle.requiresTerminalRelease = true
        lifecycles[keyCode] = lifecycle
    }

    /// Keeps Ghostty's binding identity stable for press, repeats, and release.
    ///
    /// Repeat text and consumed modifiers are event-local semantics. The
    /// unshifted codepoint participates in Ghostty's consumed-binding release
    /// hash, so it must remain paired with the initial press while the key is
    /// held, even if the active layout changes.
    public mutating func physicalIdentity(
        forKeyDown keyCode: UInt16,
        resolvedIdentity: TerminalKeyInputPhysicalIdentity,
        isRepeat: Bool,
        eventIdentity: PhysicalKeyEventIdentity? = nil
    ) -> TerminalKeyInputPhysicalIdentity {
        if var lifecycle = lifecycles[keyCode],
           isRepeat
            || eventIdentity == nil
            || lifecycle.lastEventIdentity == eventIdentity {
            if let physicalIdentity = lifecycle.physicalIdentity {
                return physicalIdentity
            }
            lifecycle.physicalIdentity = resolvedIdentity
            lifecycle.lastEventIdentity =
                eventIdentity ?? lifecycle.lastEventIdentity
            lifecycles[keyCode] = lifecycle
            return resolvedIdentity
        }

        lifecycles[keyCode] = PhysicalKeyLifecycle(
            owner: .terminal,
            physicalIdentity: resolvedIdentity,
            lastEventIdentity: eventIdentity,
            requiresTerminalRelease: true
        )
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
            forwardsPhysicalKey:
                lifecycle.owner == .terminal
                || lifecycle.requiresTerminalRelease,
            physicalIdentity: lifecycle.physicalIdentity
        )
    }

    /// Clears all key lifecycles after responder ownership changes.
    public mutating func reset() {
        lifecycles.removeAll(keepingCapacity: true)
    }
}
