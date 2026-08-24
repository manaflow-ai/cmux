import Foundation

/// One-shot marker distinguishing a backend-environment-switch rebuild from an
/// organic Stack-project flip at composition time.
///
/// The launch hygiene (`detectAuthProjectSwitch` → `clearStaleAuthOnLaunch`)
/// wipes the persisted session whenever the resolved Stack project changed,
/// which is exactly right for organic flips (a tagged Debug bundle rebuilt
/// with different baked auth) but would destroy the session the switch
/// transaction just PARKED for the target environment. The transaction arms
/// this marker inside every `storeSelection` step (both directions —
/// explicit stores and lane clears alike, including a revert's), and the
/// composition consumes it where `clearStaleAuthOnLaunch`
/// is computed: `detectAuthProjectSwitch` still RUNS (it must update the
/// stored project id), but its verdict is suppressed exactly once, so the
/// rebuilt graph restores the target's parked slot instead of clearing it.
///
/// Crash safety: a crash after arm leaves the marker persisted; the next
/// LAUNCH consumes it and restores the target's parked slot, which is the
/// correct outcome for a crash mid-switch (the override was already stored).
/// Every organic flip after that sees a consumed (absent) marker and keeps
/// today's pinned clear semantics.
public enum CMUXBackendEnvironmentSwitchRebuildMarker {
    /// The UserDefaults key the marker persists under.
    public static let defaultsKey = "cmux.backendEnvironmentSwitch.suppressAuthClearOnce"

    /// Arm the marker: the next composition pass suppresses the launch clear
    /// once. Called inside the switch transaction's `storeSelection` step, so
    /// the marker is set iff a selection commit happened.
    public static func arm(in defaults: UserDefaults) {
        defaults.set(true, forKey: defaultsKey)
    }

    /// Consume the marker: returns whether it was armed and removes it, so a
    /// single arm suppresses exactly one composition pass's clear.
    public static func consume(from defaults: UserDefaults) -> Bool {
        let armed = defaults.bool(forKey: defaultsKey)
        defaults.removeObject(forKey: defaultsKey)
        return armed
    }
}
