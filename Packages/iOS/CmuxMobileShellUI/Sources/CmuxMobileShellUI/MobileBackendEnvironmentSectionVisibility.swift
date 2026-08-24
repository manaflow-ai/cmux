#if os(iOS)
import CMUXAuthCore

/// Which backend-environment Settings section, if any, renders.
///
/// Three tiers so the strict picker gate never strands a device off
/// production:
/// - gate-allowed user or DEBUG build → the full picker,
/// - everyone else whose SELECTION resolves staging → a recovery-only
///   section (the section itself keys the switch-back button on the
///   selection: explicit staging offers it, a staging LANE shows the lane
///   explanation instead),
/// - everyone else on production, idle → nothing.
enum MobileBackendEnvironmentSectionVisibility: Equatable {
    /// The full picker (gate-allowed user or DEBUG).
    case fullPicker
    /// The recovery-only section: staging badge, explanation, and — for an
    /// explicit staging selection — a single "Switch Back to Production"
    /// button through the same confirmation machinery as the picker.
    case stagingRecovery
    /// No section.
    case hidden

    /// Derive the tier from the resolved SELECTION.
    ///
    /// The `isSwitchRunning` branch keeps the section MOUNTED mid-switch:
    /// parking detaches `currentUser`, which kills the gate clause while the
    /// active selection still reads the old value — without it the section
    /// would unmount under the overlay while the run is still resolving.
    /// A running switch away from staging stays `stagingRecovery` (the
    /// resolved-environment check wins first, and the selection remains
    /// staging-resolved until the rebuild), so the recovery section never
    /// flashes into a picker mid-run.
    static func resolve(
        isGateAllowed: Bool,
        isDebugBuild: Bool,
        isSwitchRunning: Bool,
        selection: CMUXBackendEnvironmentSelection
    ) -> Self {
        if isGateAllowed || isDebugBuild { return .fullPicker }
        if selection.resolvedEnvironment == .staging { return .stagingRecovery }
        if isSwitchRunning { return .fullPicker }
        return .hidden
    }
}
#endif
