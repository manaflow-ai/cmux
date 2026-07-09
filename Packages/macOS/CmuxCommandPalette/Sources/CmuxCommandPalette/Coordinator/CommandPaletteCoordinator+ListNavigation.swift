/// Command-palette keyboard/selection navigation and list-reaction handling
/// drained out of `ContentView`.
///
/// This extension owns the palette's scroll-target/selection bookkeeping and
/// the four list-reaction transitions that previously lived as `private`
/// methods on `ContentView`. Every method reads only coordinator-owned state,
/// the passed-in ``CommandPalettePresentationModel``, and package value types;
/// the irreducible app effects (the system beep, the SwiftUI animation wrapper,
/// the per-window debug-state sync, and the results-refresh pipeline) are
/// reached through the ``CommandPaletteListHost`` seam, and the localized
/// empty-state text is passed in as a resolved `String`.
extension CommandPaletteCoordinator {
    /// Whether the most recently resolved (non-preview) search is current: no
    /// search is pending and the resolved request id matches the latest request.
    public var hasCurrentResolvedResults: Bool {
        !isSearchPending && resolvedSearchRequestID == searchRequestID
    }

    /// Whether the palette should show its empty state: the visible list is
    /// empty and either the current results are fully resolved, or a pending
    /// search's prior empty state should be preserved for the active scope.
    public func shouldShowEmptyState(
        presentation: CommandPalettePresentationModel
    ) -> Bool {
        guard visibleResults.isEmpty else { return false }
        if hasCurrentResolvedResults {
            return true
        }

        let scope = queryScopePolicy.listScope(for: presentation.query)
        return CommandPaletteSearchOrchestrator.shouldPreserveEmptyStateWhileSearchPending(
            isSearchPending: isSearchPending,
            visibleResultsScopeMatches: visibleResultsScope == scope,
            resolvedSearchScopeMatches: resolvedSearchScope == scope,
            resolvedSearchFingerprintMatches: resolvedSearchFingerprint == visibleResultsFingerprint,
            resolvedResultsAreEmpty: cachedResults.isEmpty
        )
    }

    /// Retargets the pending scroll position to the selected row, or clears it
    /// when there are no rows. The scroll-target assignment animates through the
    /// host when `animated` is true, matching the legacy `withAnimation` site.
    public func updateScrollTarget(
        resultCount: Int,
        animated: Bool,
        presentation: CommandPalettePresentationModel,
        host: any CommandPaletteListHost
    ) {
        guard resultCount > 0 else {
            presentation.scrollTargetIndex = nil
            presentation.scrollTargetAnchor = nil
            return
        }

        let selectedIndex = clampedSelectedIndex(resultCount: resultCount, presentation: presentation)
        presentation.scrollTargetAnchor = CommandPaletteSelectionNavigation.scrollPositionAnchor(
            selectedIndex: selectedIndex,
            resultCount: resultCount
        )

        let assignTarget = {
            presentation.scrollTargetIndex = selectedIndex
        }
        if animated {
            host.commandPaletteListAnimate(assignTarget)
        } else {
            assignTarget()
        }
    }

    /// Moves the selected result index by `delta`, clamping to the visible
    /// range, re-anchors the selection, retargets the scroll position, and
    /// republishes the overlay command-list and debug state. Beeps through the
    /// host when there is nothing to move through.
    public func moveSelection(
        by delta: Int,
        presentation: CommandPalettePresentationModel,
        emptyStateText: String,
        host: any CommandPaletteListHost
    ) {
        let count = visibleResults.count
        guard count > 0 else {
            host.commandPaletteListBeep()
            return
        }
        let current = clampedSelectedIndex(resultCount: count, presentation: presentation)
        presentation.selectedResultIndex = min(max(current + delta, 0), count - 1)
        if hasCurrentResolvedResults {
            syncSelectionAnchorFromCurrentResults(presentation: presentation)
        } else {
            syncSelectionAnchorFromVisibleResults(presentation: presentation)
        }
        updateScrollTarget(resultCount: count, animated: true, presentation: presentation, host: host)
        syncOverlayCommandListState(
            presentation: presentation,
            emptyStateText: emptyStateText,
            shouldShowEmptyState: { self.shouldShowEmptyState(presentation: presentation) }
        )
        host.commandPaletteListSyncDebugState()
    }

    /// Applies the query-transition side effects (selection/scroll reset,
    /// optional results-pipeline reset, refresh scheduling, debug-state sync)
    /// when the command-list search field's query changes.
    public func handleQueryChange(
        oldQuery: String,
        newQuery: String,
        presentation: CommandPalettePresentationModel,
        host: any CommandPaletteListHost
    ) {
        presentation.selectedResultIndex = 0
        presentation.selectionAnchorCommandID = nil
        presentation.scrollTargetIndex = nil
        presentation.scrollTargetAnchor = nil
        if queryScopePolicy.shouldResetVisibleResultsForQueryTransition(
            oldQuery: oldQuery,
            newQuery: newQuery,
            hasVisibleResults: visibleResultsScope != nil
        ) {
            resetResultsPipeline()
        }
        host.commandPaletteListScheduleResultsRefresh(
            query: newQuery,
            force: false,
            preservePendingActivation: false
        )
        updateScrollTarget(resultCount: visibleResults.count, animated: false, presentation: presentation, host: host)
        host.commandPaletteListSyncDebugState()
    }

    /// Forces a corpus refresh after the search fingerprint changes, yielding
    /// one turn first so the query-state transition settles (otherwise the
    /// forced refresh can rebuild the old command list after deleting the ">"
    /// prefix).
    public func handleSearchFingerprintChange(
        presentation: CommandPalettePresentationModel,
        host: any CommandPaletteListHost
    ) {
        Task { @MainActor in
            await Task.yield()
            host.commandPaletteListScheduleResultsRefresh(
                query: presentation.query,
                force: true,
                preservePendingActivation: false
            )
            updateScrollTarget(resultCount: visibleResults.count, animated: false, presentation: presentation, host: host)
            host.commandPaletteListSyncDebugState()
        }
    }

    /// Resolves the selected result index against the freshly materialized
    /// result IDs and re-syncs the selection anchor, scroll target, overlay
    /// command-list, and debug state when the results revision advances.
    public func handleResultsRevisionChange(
        presentation: CommandPalettePresentationModel,
        emptyStateText: String,
        host: any CommandPaletteListHost
    ) {
        let resultIDs = cachedResults.map(\.id)
        presentation.selectedResultIndex = CommandPalettePendingActivation.resolvedSelectionIndex(
            preferredCommandID: presentation.selectionAnchorCommandID,
            fallbackSelectedIndex: presentation.selectedResultIndex,
            resultIDs: resultIDs
        )
        syncSelectionAnchorFromCurrentResults(presentation: presentation)
        let visibleResultCount = visibleResults.count
        updateScrollTarget(resultCount: visibleResultCount, animated: false, presentation: presentation, host: host)
        syncOverlayCommandListState(
            presentation: presentation,
            emptyStateText: emptyStateText,
            shouldShowEmptyState: { self.shouldShowEmptyState(presentation: presentation) }
        )
        host.commandPaletteListSyncDebugState()
    }

    /// Retargets the scroll position and re-syncs the overlay command-list and
    /// debug state when the selected result index changes.
    public func handleSelectedResultIndexChange(
        presentation: CommandPalettePresentationModel,
        emptyStateText: String,
        host: any CommandPaletteListHost
    ) {
        updateScrollTarget(resultCount: visibleResults.count, animated: true, presentation: presentation, host: host)
        syncOverlayCommandListState(
            presentation: presentation,
            emptyStateText: emptyStateText,
            shouldShowEmptyState: { self.shouldShowEmptyState(presentation: presentation) }
        )
        host.commandPaletteListSyncDebugState()
    }
}
