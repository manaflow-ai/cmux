/// Command-palette searchable-corpus and nucleo-index build pipeline.
///
/// This extension owns the corpus rebuild + index-build machinery drained out
/// of `ContentView`. The coordinator is the single writer of the corpus/index
/// state declared on the main type; the host supplies the live entries and is
/// called back for the post-index results refresh.
extension CommandPaletteCoordinator {
    /// Rebuilds the searchable corpus for the scope of `query` (or the host's
    /// live query) when the scope or fingerprint changed, or when `force` is
    /// set. On a rebuild it also kicks off the async nucleo-index build.
    public func refreshSearchCorpus(
        force: Bool = false,
        query: String? = nil,
        host: CommandPaletteSearchCorpusHost
    ) {
        let stateQuery = host.presentationQuery()
        let effectiveQuery = query ?? stateQuery
        let scope = queryScopePolicy.listScope(for: effectiveQuery)

        let plan = host.corpusBuildPlan(scope, effectiveQuery)
        let fingerprint = plan.fingerprint
        guard force || cachedCorpusScope != scope || cachedCorpusFingerprint != fingerprint else {
            return
        }

        let entries = host.corpusEntries(plan)
        searchCommandsByID = CommandPaletteSearchOrchestrator.firstValueDictionary(
            entries,
            keyedBy: \.id
        )
        let searchCorpus = entries.map { entry in
            CommandPaletteSearchCorpusEntry(
                payload: entry.id,
                rank: entry.rank,
                title: entry.title,
                searchableTexts: entry.searchableTexts
            )
        }
        self.searchCorpus = searchCorpus
        searchCorpusByID = CommandPaletteSearchOrchestrator.firstValueDictionary(
            searchCorpus,
            keyedBy: \.payload
        )
        cachedCorpusScope = scope
        cachedCorpusFingerprint = fingerprint
        scheduleSearchIndexBuild(
            entries: searchCorpus,
            scope: scope,
            fingerprint: fingerprint,
            host: host
        )
    }

    /// Cancels any in-flight nucleo-index build and bumps the generation so a
    /// completing build cannot apply a stale index.
    public func cancelSearchIndexBuild() {
        searchIndexBuildTask?.cancel()
        searchIndexBuildTask = nil
        searchIndexBuildGeneration &+= 1
    }

    private func scheduleSearchIndexBuild(
        entries: [CommandPaletteSearchCorpusEntry<String>],
        scope: CommandPaletteListScope,
        fingerprint: Int?,
        host: CommandPaletteSearchCorpusHost
    ) {
        cancelSearchIndexBuild()
        nucleoSearchIndex = nil
        let generation = searchIndexBuildGeneration
        // The nucleo index build is CPU work that must not block the main
        // actor, so it runs on a detached task that captures only the Sendable
        // `entries`. The host callbacks (non-Sendable, main-actor view state)
        // are applied here on the main actor after awaiting the build, never
        // captured across the isolation boundary.
        let buildTask = Task.detached(priority: .userInitiated) {
            () -> CommandPaletteNucleoSearchIndex<String>? in
            CommandPaletteNucleoSearchIndex(entries: entries)
        }
        searchIndexBuildTask = Task { @MainActor [weak self] in
            let index = await buildTask.value
            guard let self, !Task.isCancelled else { return }
            guard self.searchIndexBuildGeneration == generation,
                  self.cachedCorpusScope == scope,
                  self.cachedCorpusFingerprint == fingerprint else {
                return
            }
            self.nucleoSearchIndex = index
            self.searchIndexBuildTask = nil
            guard index != nil else { return }
            let query = host.presentationQuery()
            if host.isCommandPalettePresented(),
               queryScopePolicy.listScope(for: query) == scope {
                host.scheduleResultsRefresh(query, true)
            }
        }
    }

    /// Clears the corpus and index state and cancels the index build, for
    /// palette dismissal teardown.
    public func resetSearchCorpus() {
        searchCorpus = []
        searchCorpusByID = [:]
        searchCommandsByID = [:]
        nucleoSearchIndex = nil
        cachedCorpusScope = nil
        cachedCorpusFingerprint = nil
    }

    /// Invalidates the cached corpus fingerprint so the next refresh rebuilds,
    /// without clearing the live corpus.
    public func invalidateSearchCorpusFingerprintCache() {
        cachedCorpusFingerprint = nil
    }
}
