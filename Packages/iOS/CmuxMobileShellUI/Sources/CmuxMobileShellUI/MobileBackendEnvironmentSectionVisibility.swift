#if os(iOS)
import CMUXAuthCore

/// Which backend-environment Settings section, if any, renders.
///
/// Three tiers so the strict picker gate never strands a device off
/// production:
/// - gate-allowed user or DEBUG build → the full Production/Staging picker,
/// - everyone else on a staging device → a recovery-only "Switch Back to
///   Production" section,
/// - everyone else on production, idle → nothing.
enum MobileBackendEnvironmentSectionVisibility: Equatable {
    /// The full Production/Staging picker (gate-allowed user or DEBUG).
    case fullPicker
    /// The recovery-only section: staging badge, explanation, and a single
    /// "Switch Back to Production" button through the same confirmation
    /// machinery as the picker.
    case stagingRecovery
    /// No section.
    case hidden

    /// Derive the tier.
    ///
    /// The `isSwitchRunning` branch keeps the section MOUNTED mid-switch:
    /// parking detaches `currentUser`, which kills the gate clause while the
    /// active environment still reads the old value — without it the section
    /// would unmount under the overlay while the run is still resolving.
    /// A running switch away from staging stays `stagingRecovery` (the
    /// `active` check wins first, and `active` remains `.staging` until the
    /// rebuild), so the recovery section never flashes into a picker
    /// mid-run.
    static func resolve(
        isGateAllowed: Bool,
        isDebugBuild: Bool,
        isSwitchRunning: Bool,
        active: CMUXBackendEnvironmentOverride
    ) -> Self {
        if isGateAllowed || isDebugBuild { return .fullPicker }
        if active == .staging { return .stagingRecovery }
        if isSwitchRunning { return .fullPicker }
        return .hidden
    }
}
#endif
