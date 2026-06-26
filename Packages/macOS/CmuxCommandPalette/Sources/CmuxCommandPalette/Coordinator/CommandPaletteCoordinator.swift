public import Observation

/// `@MainActor @Observable` orchestrator for the per-window command palette.
///
/// The coordinator is the single seam every command-palette slice routes
/// through. It owns the palette's render-list publication: the host computes a
/// ``CommandPaletteCommandListRenderState`` from its live palette state and
/// hands it to ``scheduleCommandListUpdate(_:)``; the coordinator coalesces
/// rapid updates on the main actor and publishes the latest snapshot through
/// ``commandList`` for the paired UI list view to observe.
///
/// ## Isolation
///
/// All palette presentation, selection, and list state is driven from the main
/// actor (SwiftUI view updates, keyboard handling, socket-command dispatch that
/// hops to main), so the coordinator is `@MainActor`. It does no I/O itself;
/// search and command execution stay with their owning collaborators and feed
/// snapshots in.
///
/// ## Update coalescing
///
/// `scheduleCommandListUpdate(_:)` stamps each call with a monotonic sequence,
/// then yields once before applying so a burst of synchronous updates within a
/// single main-actor turn collapses to the newest. A snapshot is dropped if a
/// newer sequence has already applied, or if its `resultsVersion` is older than
/// the last applied results version. Identical snapshots are not republished.
/// This reproduces the legacy `CommandPaletteOverlayRenderModel` contract
/// byte-for-byte.
@MainActor
@Observable
public final class CommandPaletteCoordinator {
    /// The latest published command-list render snapshot.
    public private(set) var commandList: CommandPaletteCommandListRenderState = .empty

    @ObservationIgnored private var scheduledCommandListSequence: UInt64 = 0
    @ObservationIgnored private var appliedCommandListSequence: UInt64 = 0
    @ObservationIgnored private var appliedCommandListResultsVersion: UInt64 = 0

    /// The current searchable corpus for the active scope.
    ///
    /// The coordinator is the single writer of the corpus + nucleo-index state;
    /// the host (`ContentView`) reads it to drive the results-refresh pipeline.
    /// All corpus state is `@ObservationIgnored`: it is consumed by the
    /// imperative search pipeline, not by SwiftUI body reads, and observing it
    /// would re-render the palette on every background rebuild.
    @ObservationIgnored public internal(set) var searchCorpus: [CommandPaletteSearchCorpusEntry<String>] = []

    /// The corpus keyed by command id, for candidate-restricted lookups.
    @ObservationIgnored public internal(set) var searchCorpusByID: [String: CommandPaletteSearchCorpusEntry<String>] = [:]

    /// The active scope's commands keyed by id, for materializing results.
    @ObservationIgnored public internal(set) var searchCommandsByID: [String: CommandPaletteCommand] = [:]

    /// The nucleo FFI search index for the active corpus, or `nil` while it is
    /// being (re)built or unavailable.
    @ObservationIgnored public internal(set) var nucleoSearchIndex: CommandPaletteNucleoSearchIndex<String>?

    /// Scope of the corpus currently cached, for the rebuild-skip decision.
    @ObservationIgnored public internal(set) var cachedCorpusScope: CommandPaletteListScope?

    /// Fingerprint of the corpus currently cached, for the rebuild-skip
    /// decision and for the results-refresh apply guards.
    @ObservationIgnored public internal(set) var cachedCorpusFingerprint: Int?

    @ObservationIgnored var searchIndexBuildTask: Task<Void, Never>?
    @ObservationIgnored var searchIndexBuildGeneration: UInt64 = 0

    // MARK: - Results pipeline state

    /// The latest fully-resolved (non-preview) search results for the active
    /// query, materialized from the resolved matches.
    ///
    /// The coordinator is the single writer of the imperative results-pipeline
    /// state below: the host drives `scheduleResultsRefresh` (in
    /// ``CommandPaletteSearchCorpusHost``), which reads/writes these fields
    /// rather than holding its own `@State`. They are `@ObservationIgnored`
    /// because they feed the imperative search pipeline and the published
    /// ``commandList`` snapshot, not SwiftUI body reads; observing them would
    /// re-render the palette on every background search apply.
    @ObservationIgnored public var cachedResults: [CommandPaletteSearchResult] = []

    /// The results currently shown in the list, which may be a preview slice
    /// applied ahead of the fully-resolved set.
    @ObservationIgnored public var visibleResults: [CommandPaletteSearchResult] = []

    /// Monotonic version bumped whenever ``visibleResults`` is reassigned, used
    /// to coalesce stale render-state publications.
    @ObservationIgnored public var visibleResultsVersion: UInt64 = 0

    /// Scope the current ``visibleResults`` were computed for, or `nil` when the
    /// visible list has been cleared.
    @ObservationIgnored public var visibleResultsScope: CommandPaletteListScope?

    /// Corpus fingerprint the current ``visibleResults`` were computed for.
    @ObservationIgnored public var visibleResultsFingerprint: Int?

    /// The in-flight detached search task, or `nil` when no search is running.
    @ObservationIgnored public var searchTask: Task<Void, Never>?

    /// Monotonic id stamped on each refresh request, so a completing search can
    /// detect that a newer request superseded it.
    @ObservationIgnored public var searchRequestID: UInt64 = 0

    /// The request id of the most recently fully-resolved (non-preview) search.
    @ObservationIgnored public var resolvedSearchRequestID: UInt64 = 0

    /// Scope of the most recently fully-resolved search.
    @ObservationIgnored public var resolvedSearchScope: CommandPaletteListScope?

    /// Corpus fingerprint of the most recently fully-resolved search.
    @ObservationIgnored public var resolvedSearchFingerprint: Int?

    /// Matching query of the most recently fully-resolved search.
    @ObservationIgnored public var resolvedMatchingQuery: String = ""

    /// Whether a search is in flight whose resolved results have not yet applied.
    @ObservationIgnored public var isSearchPending: Bool = false

    /// Pure query/scope policy the corpus pipeline resolves list scope through.
    @ObservationIgnored let queryScopePolicy = CommandPaletteQueryScopePolicy()

    /// Creates a coordinator with an empty command list.
    public init() {}

    /// Cancels the in-flight search task and clears the handle.
    public func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
    }

    /// Clears every results-pipeline field back to its empty state, for palette
    /// reset/dismissal. Bumps ``visibleResultsVersion`` so a stale publication
    /// cannot re-show cleared results.
    public func resetResultsPipeline() {
        cachedResults = []
        visibleResults = []
        visibleResultsScope = nil
        visibleResultsFingerprint = nil
        visibleResultsVersion &+= 1
    }

    /// Schedules `state` to become the published ``commandList``.
    ///
    /// The update is coalesced on the main actor: only the newest scheduled
    /// snapshot with a non-stale `resultsVersion` is applied, and an applied
    /// snapshot equal to the current value is not republished.
    public func scheduleCommandListUpdate(_ state: CommandPaletteCommandListRenderState) {
        scheduledCommandListSequence &+= 1
        let sequence = scheduledCommandListSequence

        Task { @MainActor in
            await Task.yield()
            guard sequence >= appliedCommandListSequence else { return }
            guard state.resultsVersion >= appliedCommandListResultsVersion else { return }
            appliedCommandListSequence = sequence
            appliedCommandListResultsVersion = max(appliedCommandListResultsVersion, state.resultsVersion)
            updateCommandList(state)
        }
    }

    private func updateCommandList(_ state: CommandPaletteCommandListRenderState) {
        guard commandList != state else { return }
        commandList = state
    }
}
