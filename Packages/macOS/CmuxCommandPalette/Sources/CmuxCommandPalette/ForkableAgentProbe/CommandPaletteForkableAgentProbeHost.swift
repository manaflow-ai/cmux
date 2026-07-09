public import Foundation

/// Read-and-act seam the host fills so ``CommandPaletteForkableAgentProbeCoordinator``
/// can drive the per-panel forkable-agent availability cache without importing
/// any app-target agent type.
///
/// The coordinator owns the cache state machine (per-panel support flags,
/// resolved snapshots, fingerprints, remote-context flags, and the
/// generation-guarded probe tasks). Everything that requires knowledge of the
/// host's restorable agent-snapshot value type stays on the conformer side:
/// deriving a snapshot's fingerprint, classifying its fork availability, reading
/// the live fallback snapshot for a panel, running the asynchronous fork
/// capability probe, and refreshing the visible command-palette results once a
/// probe changes availability. `Snapshot` is the host's snapshot value type; the
/// coordinator never inspects it, it only stores and forwards it.
@MainActor
public protocol CommandPaletteForkableAgentProbeHost {
    /// The host's restorable agent-snapshot value type.
    associatedtype Snapshot: Sendable

    /// Stable fingerprint of a snapshot, used to detect when a panel's fallback
    /// snapshot changed and the cached probe result must be invalidated.
    func commandPaletteForkSnapshotFingerprint(_ snapshot: Snapshot) -> String

    /// Classifies whether a snapshot can seed a fork command and whether
    /// confirming that needs an asynchronous capability probe.
    func commandPaletteSnapshotForkAvailability(
        _ snapshot: Snapshot,
        isRemoteTerminal: Bool
    ) -> CommandPaletteForkSnapshotAvailability

    /// The fingerprint of the live fallback snapshot currently bound to the
    /// given panel, or `nil` if the focused panel no longer matches. Used inside
    /// a completed probe to discard a result whose panel's fallback changed
    /// while the probe was in flight.
    func commandPaletteCurrentFallbackSnapshotFingerprint(
        workspaceId: UUID,
        panelId: UUID
    ) -> String?

    /// Runs the asynchronous fork-capability probe for a panel. The host loads
    /// the restorable-agent session index, resolves the snapshot for the panel
    /// (falling back to `fallbackSnapshot`), and asks the agent runtime whether
    /// that snapshot supports forking.
    func commandPaletteProbeForkableAgentSupport(
        workspaceId: UUID,
        panelId: UUID,
        fallbackSnapshot: Snapshot?,
        isRemoteTerminal: Bool
    ) async -> CommandPaletteForkableAgentProbeResult<Snapshot>

    /// Refreshes the visible command-palette results after a probe changed a
    /// panel's forkable-agent availability, but only while the palette is
    /// presented and the given panel is still the active probe panel. The host
    /// owns the presented-state check and the results-refresh call.
    func commandPaletteRefreshResultsAfterForkableAgentProbe(activePanelKey: String)
}
