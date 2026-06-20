/// The host-resolved plan for one command-palette corpus rebuild.
///
/// Produced by ``CommandPaletteSearchCorpusHost/commandPaletteCorpusBuildPlan(for:)``
/// and consumed by ``CommandPaletteCoordinator`` to decide whether a rebuild is
/// needed (scope + fingerprint vs the cached corpus). Resolving a plan performs
/// the host's unconditional per-refresh side effects (refreshing forkable-agent
/// availability, resolving terminal-open targets); the heavier entry list is
/// only materialized — via ``CommandPaletteSearchCorpusHost/commandPaletteCorpusEntries(for:plan:)``
/// — when the coordinator decides a rebuild is required, matching the legacy
/// `refreshCommandPaletteSearchCorpus` ordering where entries were built only
/// after the skip guard passed.
public struct CommandPaletteSearchCorpusBuildPlan {
    /// The list scope this plan is for.
    public let scope: CommandPaletteListScope

    /// Whether the switcher build should expand to per-surface rows.
    public let includeSurfaces: Bool

    /// Fingerprint of the entries; the coordinator skips a rebuild when the
    /// scope and fingerprint are unchanged (and the rebuild is not forced).
    public let fingerprint: Int

    /// Creates a corpus build plan.
    public init(
        scope: CommandPaletteListScope,
        includeSurfaces: Bool,
        fingerprint: Int
    ) {
        self.scope = scope
        self.includeSurfaces = includeSurfaces
        self.fingerprint = fingerprint
    }
}
