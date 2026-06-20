/// The app-side seam the command-palette corpus pipeline reads back through.
///
/// The corpus and nucleo-index build live on ``CommandPaletteCoordinator``, but
/// the *content* of a corpus (which commands and switcher rows exist, their
/// fingerprint, whether the palette is presented, the live query) is owned by
/// the per-window host in the app target. The host is passed in as a value of
/// closures rather than a delegate object because the conforming owner is a
/// SwiftUI `View` struct (`ContentView`), which cannot be a `weak` delegate;
/// closure injection keeps the seam working across the struct boundary while
/// the coordinator stays the single writer of the corpus/index state.
///
/// ## Isolation
///
/// Every closure is `@MainActor`: corpus rebuilds, the index-build completion,
/// and the results refresh all run on the main actor (SwiftUI view updates,
/// keyboard handling, socket commands that hop to main).
@MainActor
public struct CommandPaletteSearchCorpusHost {
    /// Reads whether the command palette is currently presented.
    public let isCommandPalettePresented: () -> Bool

    /// Reads the palette's live query string.
    public let presentationQuery: () -> String

    /// Resolves the corpus-build plan for a scope and the effective query that
    /// produced it: the fingerprint and surface inclusion the coordinator's
    /// rebuild-skip decision needs. Resolving a plan performs the host's
    /// unconditional per-refresh side effects (refreshing forkable-agent
    /// availability, resolving terminal-open targets, reading the config
    /// revision), matching the legacy ordering where these ran before the skip
    /// guard.
    public let corpusBuildPlan: (_ scope: CommandPaletteListScope, _ effectiveQuery: String) -> CommandPaletteSearchCorpusBuildPlan

    /// Materializes the live palette entries for a plan. Called only when the
    /// coordinator decides a rebuild is required, so the heavier entry build is
    /// skipped on a no-op refresh exactly as the legacy code did.
    public let corpusEntries: (CommandPaletteSearchCorpusBuildPlan) -> [CommandPaletteCommand]

    /// Schedules a results refresh against the current corpus/index. Called by
    /// the index-build completion once a freshly built nucleo index is applied
    /// while the palette is presented in the same scope.
    public let scheduleResultsRefresh: (_ query: String, _ preservePendingActivation: Bool) -> Void

    /// Creates a corpus host from the per-window app callbacks.
    public init(
        isCommandPalettePresented: @escaping () -> Bool,
        presentationQuery: @escaping () -> String,
        corpusBuildPlan: @escaping (_ scope: CommandPaletteListScope, _ effectiveQuery: String) -> CommandPaletteSearchCorpusBuildPlan,
        corpusEntries: @escaping (CommandPaletteSearchCorpusBuildPlan) -> [CommandPaletteCommand],
        scheduleResultsRefresh: @escaping (_ query: String, _ preservePendingActivation: Bool) -> Void
    ) {
        self.isCommandPalettePresented = isCommandPalettePresented
        self.presentationQuery = presentationQuery
        self.corpusBuildPlan = corpusBuildPlan
        self.corpusEntries = corpusEntries
        self.scheduleResultsRefresh = scheduleResultsRefresh
    }
}
