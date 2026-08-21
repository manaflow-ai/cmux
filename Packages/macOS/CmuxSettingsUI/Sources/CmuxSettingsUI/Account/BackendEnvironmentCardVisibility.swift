import Foundation

/// Which backend-environment card, if any, the Account section renders.
///
/// Three tiers so the strict picker gate never strands a device off
/// production:
/// - gate-allowed user or DEBUG build → the full picker,
/// - everyone else on a non-production device (or with a switch in flight)
///   → a recovery-only "Switch Back to Production" card,
/// - everyone else on production, idle → nothing.
public enum BackendEnvironmentCardVisibility: Equatable, Sendable {
    /// The full Production/Staging picker (gate-allowed user or DEBUG).
    case fullPicker
    /// The recovery-only card: staging badge, explanation, and a single
    /// "Switch Back to Production" button.
    case recovery
    /// No card.
    case hidden

    /// Derive the tier.
    ///
    /// The recovery clause deliberately also fires while a switch is in any
    /// non-idle phase: (a) a release-build gate user's card would otherwise
    /// vanish mid-switch (parking detaches `currentUser`, killing the gate
    /// clause while the active environment still reads production), and
    /// (b) the recovery card would disappear the instant the switch-back
    /// rebind flips active to production, so the progress row and outcome
    /// note would never render. The phase term keeps one card visible
    /// through the whole run.
    public init(
        pickerAllowed: Bool,
        activeEnvironment: AccountBackendEnvironment,
        switchPhase: AccountBackendEnvironmentSwitchPhase
    ) {
        if pickerAllowed {
            self = .fullPicker
        } else if activeEnvironment != .production || switchPhase != .idle {
            self = .recovery
        } else {
            self = .hidden
        }
    }
}

extension AccountFlow {
    /// The card tier this flow's current state resolves to.
    public var backendEnvironmentCardVisibility: BackendEnvironmentCardVisibility {
        BackendEnvironmentCardVisibility(
            pickerAllowed: backendEnvironmentPickerAllowed,
            activeEnvironment: activeBackendEnvironment,
            switchPhase: backendEnvironmentSwitchPhase
        )
    }
}
