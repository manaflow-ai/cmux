/// Outcome of one forkable-agent availability probe for a terminal panel.
///
/// The host conformer of ``CommandPaletteForkableAgentProbeHost`` runs the
/// actual capability detection (loading the restorable-agent session index and
/// asking the agent runtime whether the resolved snapshot can be forked) and
/// returns this value so the coordinator can update its per-panel cache without
/// importing any app-target agent type. `Snapshot` is the host's restorable
/// agent-snapshot value type; the coordinator stores it opaquely.
public struct CommandPaletteForkableAgentProbeResult<Snapshot: Sendable>: Sendable {
    /// Whether the resolved snapshot supports forking in this panel context.
    public let supportsFork: Bool
    /// The snapshot the probe resolved for the panel, if any. This is the live
    /// index snapshot when present, otherwise the fallback snapshot the caller
    /// passed in, otherwise `nil`.
    public let resolvedSnapshot: Snapshot?
    /// `true` when the probe resolved no live index snapshot and instead fell
    /// back to the caller-supplied fallback snapshot. Drives the cached
    /// "result had fallback" flag that forces a re-probe on the next refresh.
    public let usedFallbackSnapshot: Bool

    /// Creates a probe result.
    public init(
        supportsFork: Bool,
        resolvedSnapshot: Snapshot?,
        usedFallbackSnapshot: Bool
    ) {
        self.supportsFork = supportsFork
        self.resolvedSnapshot = resolvedSnapshot
        self.usedFallbackSnapshot = usedFallbackSnapshot
    }
}
