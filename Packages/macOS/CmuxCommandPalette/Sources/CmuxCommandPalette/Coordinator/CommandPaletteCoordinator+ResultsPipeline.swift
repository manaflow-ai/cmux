import Foundation

/// Command-palette results-refresh pipeline drained out of `ContentView`.
///
/// This extension owns the full results-refresh flow: it rebuilds the search
/// corpus through the ``CommandPaletteSearchCorpusHost`` seam, stamps a new
/// request id, optionally seeds resolved results synchronously, and otherwise
/// runs the detached preview/resolved search task that applies its results back
/// on the main actor. Every coordinator-owned field (corpus, index, request and
/// resolution stamps, the in-flight `searchTask`) is read and written here as
/// the single writer; the irreducible app effects, the presented-state read,
/// the per-window debug-state sync, and the resolved-activation runner, are
/// reached through the ``CommandPaletteSearchCorpusHost`` and
/// ``CommandPaletteListHost`` seams, and the localized empty-state text is
/// passed in as a resolved `String`.
extension CommandPaletteCoordinator {
    /// Upper bound on preview results applied ahead of the fully-resolved set.
    private static let visiblePreviewResultLimit = 48

    /// Upper bound on candidate command ids carried into a preview search.
    private static let visiblePreviewCandidateLimit = 128

    /// Refreshes the palette results for `query` (or the live presentation
    /// query): rebuilds the corpus through `corpusHost`, stamps a new request,
    /// seeds resolved results synchronously when the corpus/index are ready, and
    /// otherwise launches the detached preview/resolved search task. The host
    /// seams supply the presented-state read, the debug-state sync, and the
    /// resolved-activation runner.
    public func scheduleResultsRefresh(
        query: String? = nil,
        forceSearchCorpusRefresh: Bool = false,
        preservePendingActivation: Bool = false,
        presentation: CommandPalettePresentationModel,
        emptyStateText: String,
        corpusHost: CommandPaletteSearchCorpusHost,
        listHost: any CommandPaletteListHost
    ) {
        let effectiveQuery = query ?? presentation.query
        let scope = queryScopePolicy.listScope(for: effectiveQuery)
        let matchingQuery = queryScopePolicy.queryForMatching(
            query: effectiveQuery,
            scope: scope
        )

        refreshSearchCorpus(
            force: forceSearchCorpusRefresh,
            query: effectiveQuery,
            host: corpusHost
        )

        searchRequestID &+= 1
        let requestID = searchRequestID
        let fingerprint = cachedCorpusFingerprint
        let searchCorpus = self.searchCorpus
        let searchCorpusByID = self.searchCorpusByID
        let searchIndex = nucleoSearchIndex
        let commandsByID = searchCommandsByID
        let usageHistory = presentation.usageHistoryByCommandId
        let queryIsEmpty = CommandPaletteFuzzyMatcher.preparedQuery(matchingQuery).isEmpty
        let historyTimestamp = Date().timeIntervalSince1970
        let policy = queryScopePolicy
        let additionalScoreBoost: @Sendable (String, Bool) -> Int = { commandId, _ in
            policy.forkPriorityBoost(commandId: commandId, query: matchingQuery)
        }
        let visiblePreviewResultLimit = Self.visiblePreviewResultLimit
        if preservePendingActivation {
            presentation.pendingActivation = presentation.pendingActivation?.rebased(
                toRequestID: requestID
            )
        } else {
            presentation.pendingActivation = nil
        }
        cancelSearch()
        if CommandPaletteSearchOrchestrator.shouldSynchronouslySeedResults(
            hasVisibleResultsForScope: visibleResultsScope == scope,
            hasSearchIndex: searchIndex != nil,
            corpusCount: searchCorpus.count
        ) {
            let matches = CommandPaletteSearchOrchestrator().resolvedSearchMatches(
                searchIndex: searchIndex,
                searchCorpus: searchCorpus,
                searchCorpusByID: searchCorpusByID,
                query: matchingQuery,
                usageHistory: usageHistory,
                queryIsEmpty: queryIsEmpty,
                historyTimestamp: historyTimestamp,
                additionalScoreBoost: additionalScoreBoost
            )
            cachedResults = CommandPaletteCoordinator.materializedSearchResults(
                matches: matches,
                commandsByID: commandsByID
            )
            let resultIDs = cachedResults.map(\.id)
            let pendingActivationResolution = presentation.pendingActivation.resolution(
                requestID: requestID,
                resultIDs: resultIDs
            )
            resolvedSearchRequestID = requestID
            resolvedSearchScope = scope
            resolvedSearchFingerprint = fingerprint
            resolvedMatchingQuery = matchingQuery
            isSearchPending = false
            setVisibleResults(
                cachedResults,
                scope: scope,
                fingerprint: fingerprint,
                presentation: presentation,
                emptyStateText: emptyStateText,
                shouldShowEmptyState: { self.shouldShowEmptyState(presentation: presentation) }
            )
            if pendingActivationResolution.shouldClearPendingActivation {
                presentation.pendingActivation = nil
            }
            presentation.resultsRevision &+= 1
            if let resolvedActivation = pendingActivationResolution.resolvedActivation {
                listHost.commandPaletteListRunResolvedActivation(resolvedActivation)
            }
            return
        }
        let previewCandidateCommandIDs: [String]
        if visibleResultsScope == scope,
           visibleResultsFingerprint == fingerprint,
           !visibleResults.isEmpty {
            previewCandidateCommandIDs = CommandPaletteSearchOrchestrator.previewCandidateCommandIDs(
                resultIDs: visibleResults.map(\.id),
                limit: Self.visiblePreviewCandidateLimit
            )
        } else {
            previewCandidateCommandIDs = []
        }
        let shouldApplyPreviewResults = scope == .commands || !previewCandidateCommandIDs.isEmpty
        isSearchPending = true
        syncOverlayCommandListState(
            presentation: presentation,
            emptyStateText: emptyStateText,
            shouldShowEmptyState: { self.shouldShowEmptyState(presentation: presentation) }
        )

        searchTask = Task.detached(priority: .userInitiated) {
            let previewMatches = shouldApplyPreviewResults
                ? CommandPaletteSearchOrchestrator().previewSearchMatches(
                    scope: scope,
                    searchIndex: searchIndex,
                    searchCorpus: searchCorpus,
                    candidateCommandIDs: previewCandidateCommandIDs,
                    searchCorpusByID: searchCorpusByID,
                    query: matchingQuery,
                    usageHistory: usageHistory,
                    queryIsEmpty: queryIsEmpty,
                    historyTimestamp: historyTimestamp,
                    additionalScoreBoost: additionalScoreBoost,
                    resultLimit: visiblePreviewResultLimit
                )
                : []

            guard !Task.isCancelled else { return }

            await MainActor.run {
                let currentScope = self.queryScopePolicy.listScope(for: presentation.query)
                let currentMatchingQuery = self.queryScopePolicy.queryForMatching(
                    query: presentation.query,
                    scope: currentScope
                )
                let shouldApplyPreview = self.searchRequestID == requestID
                    && corpusHost.isCommandPalettePresented()
                    && currentScope == scope
                    && currentMatchingQuery == matchingQuery
                    && self.cachedCorpusFingerprint == fingerprint
                    && self.isSearchPending
                guard shouldApplyPreview else {
                    return
                }
                guard shouldApplyPreviewResults else {
                    return
                }

                let previewResults = CommandPaletteCoordinator.materializedSearchResults(
                    matches: previewMatches,
                    commandsByID: self.searchCommandsByID
                )
                self.setVisibleResults(
                    previewResults,
                    scope: scope,
                    fingerprint: fingerprint,
                    presentation: presentation,
                    emptyStateText: emptyStateText,
                    shouldShowEmptyState: { self.shouldShowEmptyState(presentation: presentation) }
                )
                self.updateScrollTarget(
                    resultCount: previewResults.count,
                    animated: false,
                    presentation: presentation,
                    host: listHost
                )
                self.syncOverlayCommandListState(
                    presentation: presentation,
                    emptyStateText: emptyStateText,
                    shouldShowEmptyState: { self.shouldShowEmptyState(presentation: presentation) }
                )
                listHost.commandPaletteListSyncDebugState()
            }

            guard !Task.isCancelled else { return }

            let matches = CommandPaletteSearchOrchestrator().resolvedSearchMatches(
                searchIndex: searchIndex,
                searchCorpus: searchCorpus,
                searchCorpusByID: searchCorpusByID,
                query: matchingQuery,
                usageHistory: usageHistory,
                queryIsEmpty: queryIsEmpty,
                historyTimestamp: historyTimestamp,
                additionalScoreBoost: additionalScoreBoost,
                shouldCancel: { Task.isCancelled }
            )

            guard !Task.isCancelled else { return }

            await MainActor.run {
                let currentScope = self.queryScopePolicy.listScope(for: presentation.query)
                let currentMatchingQuery = self.queryScopePolicy.queryForMatching(
                    query: presentation.query,
                    scope: currentScope
                )
                let shouldApplyResults = self.searchRequestID == requestID
                    && corpusHost.isCommandPalettePresented()
                    && currentScope == scope
                    && currentMatchingQuery == matchingQuery
                    && self.cachedCorpusFingerprint == fingerprint
                guard shouldApplyResults else {
                    return
                }

                self.cachedResults = CommandPaletteCoordinator.materializedSearchResults(
                    matches: matches,
                    commandsByID: self.searchCommandsByID
                )
                let resultIDs = self.cachedResults.map(\.id)
                let pendingActivationResolution = presentation.pendingActivation.resolution(
                    requestID: requestID,
                    resultIDs: resultIDs
                )
                self.resolvedSearchRequestID = requestID
                self.resolvedSearchScope = scope
                self.resolvedSearchFingerprint = fingerprint
                self.resolvedMatchingQuery = matchingQuery
                self.isSearchPending = false
                self.setVisibleResults(
                    self.cachedResults,
                    scope: scope,
                    fingerprint: fingerprint,
                    presentation: presentation,
                    emptyStateText: emptyStateText,
                    shouldShowEmptyState: { self.shouldShowEmptyState(presentation: presentation) }
                )
                if pendingActivationResolution.shouldClearPendingActivation {
                    presentation.pendingActivation = nil
                }
                presentation.resultsRevision &+= 1
                if self.searchRequestID == requestID {
                    self.searchTask = nil
                }
                if let resolvedActivation = pendingActivationResolution.resolvedActivation {
                    listHost.commandPaletteListRunResolvedActivation(resolvedActivation)
                }
            }
        }
    }
}
