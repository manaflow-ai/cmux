import Foundation

extension MobileShellComposite {
    /// Whether any foreground Mac switch attempt is currently in flight.
    ///
    /// `switchToMac` returns `false` both for a genuine connection failure and
    /// for an attempt superseded by a newer switch (which leaves the newer
    /// attempt's id in place; `finishMacSwitchAttempt` only clears a matching
    /// id). Reconnect UIs read this at result time to avoid showing a
    /// "couldn't connect" alert for an attempt that merely lost the race to a
    /// switch the user started elsewhere.
    ///
    /// Lives in an extension file (with `macSwitchAttemptID` made internal)
    /// instead of `MobileShellComposite.swift` to respect that file's length
    /// budget.
    public var isMacSwitchInFlight: Bool { macSwitchAttemptID != nil }

    /// Assign any newly seen real Mac a stable in-memory color slot.
    ///
    /// Called from `recomputeDerivedWorkspaceState()` before deriving
    /// previews so a Mac switch's transient single-key `workspacesByMac`
    /// state (old foreground dropped synchronously, new foreground's
    /// siblings re-added asynchronously) never recomputes another Mac's
    /// existing slot. Lives here (with `stableMacColorSlots` and
    /// `workspaceAggregation` made internal) instead of
    /// `MobileShellComposite.swift` to respect that file's length budget.
    func updateStableMacColorSlots() {
        let updated = workspaceAggregation.machineColorIndex(
            existingAssignments: stableMacColorSlots,
            adding: Array(workspacesByMac.keys.filter { !$0.isEmpty && $0 != Self.foregroundAnonymousKey })
        )
        if updated != stableMacColorSlots {
            stableMacColorSlots = updated
        }
    }
}
