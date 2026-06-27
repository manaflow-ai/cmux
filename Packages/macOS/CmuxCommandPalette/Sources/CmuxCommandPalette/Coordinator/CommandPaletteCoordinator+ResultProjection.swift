import SwiftUI

/// Command-palette result/render projection drained out of `ContentView`.
///
/// This extension owns the pure projection from the coordinator's resolved
/// search state into the published render snapshots, plus the visible-results
/// writer and the selection-anchor/scroll bookkeeping. Every method reads only
/// coordinator-owned state, the passed-in ``CommandPalettePresentationModel``,
/// and package value types; the host (`ContentView`) forwards the two app-side
/// reads it cannot move (the localized empty-state text and the empty-state
/// visibility decision) as a resolved `String` and a `@MainActor` closure.
extension CommandPaletteCoordinator {
    /// Materializes resolved fuzzy matches into search results, dropping any
    /// match whose command is no longer in `commandsByID`.
    public static func materializedSearchResults(
        matches: [CommandPaletteResolvedSearchMatch],
        commandsByID: [String: CommandPaletteCommand]
    ) -> [CommandPaletteSearchResult] {
        matches.compactMap { match in
            guard let command = commandsByID[match.commandID] else { return nil }
            return CommandPaletteSearchResult(
                command: command,
                score: match.score,
                titleMatchIndices: match.titleMatchIndices
            )
        }
    }

    /// Replaces the visible results (and their scope/fingerprint), bumps the
    /// visible-results version, and republishes the overlay command-list state.
    ///
    /// The empty-state visibility is taken as a closure so it is evaluated after
    /// the visible-results mutation, matching the legacy ordering where the
    /// snapshot read the recomputed value.
    public func setVisibleResults(
        _ results: [CommandPaletteSearchResult],
        scope: CommandPaletteListScope,
        fingerprint: Int?,
        presentation: CommandPalettePresentationModel,
        emptyStateText: String,
        shouldShowEmptyState: () -> Bool
    ) {
        visibleResults = results
        visibleResultsScope = scope
        visibleResultsFingerprint = fingerprint
        visibleResultsVersion &+= 1
        syncOverlayCommandListState(
            presentation: presentation,
            emptyStateText: emptyStateText,
            shouldShowEmptyState: shouldShowEmptyState
        )
    }

    /// The trailing accessory for `command`: its keyboard-shortcut hint when one
    /// exists, otherwise its kind label, otherwise none.
    public func renderTrailingLabel(
        for command: CommandPaletteCommand
    ) -> CommandPaletteRenderTrailingLabel? {
        if let shortcutHint = command.shortcutHint {
            return CommandPaletteRenderTrailingLabel(text: shortcutHint, style: .shortcut)
        }

        if let kindLabel = command.kindLabel {
            return CommandPaletteRenderTrailingLabel(text: kindLabel, style: .kind)
        }
        return nil
    }

    /// Builds the overlay command-list render snapshot from the current visible
    /// results and the supplied presentation/empty-state inputs.
    public func overlayCommandListStateSnapshot(
        presentation: CommandPalettePresentationModel,
        emptyStateText: String,
        shouldShowEmptyState: Bool
    ) -> CommandPaletteCommandListRenderState {
        let rows = visibleResults.map { result in
            CommandPaletteRenderResultRow(
                id: result.id,
                title: result.command.title,
                matchedIndices: result.titleMatchIndices,
                trailingLabel: renderTrailingLabel(for: result.command)
            )
        }
        let selectedIndex = clampedSelectedIndex(resultCount: rows.count, presentation: presentation)
        return CommandPaletteCommandListRenderState(
            resultsVersion: visibleResultsVersion,
            emptyStateText: emptyStateText,
            listIdentity: queryScopePolicy.listIdentity(for: presentation.query),
            rows: rows,
            selectedIndex: selectedIndex,
            shouldShowEmptyState: shouldShowEmptyState,
            scrollTargetID: scrollTargetID(rows: rows, presentation: presentation),
            scrollTargetAnchor: presentation.scrollTargetAnchor
        )
    }

    /// The identity of the row at the pending scroll-target index, or `nil` when
    /// there is no pending target or it is out of range.
    public func scrollTargetID(
        rows: [CommandPaletteRenderResultRow],
        presentation: CommandPalettePresentationModel
    ) -> String? {
        guard let index = presentation.scrollTargetIndex,
              rows.indices.contains(index) else {
            return nil
        }
        return rows[index].id
    }

    /// Recomputes and schedules the overlay command-list render snapshot.
    public func syncOverlayCommandListState(
        presentation: CommandPalettePresentationModel,
        emptyStateText: String,
        shouldShowEmptyState: () -> Bool
    ) {
        scheduleCommandListUpdate(
            overlayCommandListStateSnapshot(
                presentation: presentation,
                emptyStateText: emptyStateText,
                shouldShowEmptyState: shouldShowEmptyState()
            )
        )
    }

    /// The clamped selected-result index for a list of `resultCount` rows.
    public func clampedSelectedIndex(
        resultCount: Int,
        presentation: CommandPalettePresentationModel
    ) -> Int {
        guard resultCount > 0 else { return 0 }
        return min(max(presentation.selectedResultIndex, 0), resultCount - 1)
    }

    /// Anchors the selection to the command id at the selected index within
    /// `resultIDs`, surviving subsequent result reorders.
    public func syncSelectionAnchor(
        resultIDs: [String],
        presentation: CommandPalettePresentationModel
    ) {
        presentation.selectionAnchorCommandID = CommandPaletteSelectionNavigation.selectionAnchorCommandID(
            selectedIndex: presentation.selectedResultIndex,
            resultIDs: resultIDs
        )
    }

    /// Anchors the selection from the resolved (cached) results.
    public func syncSelectionAnchorFromCurrentResults(
        presentation: CommandPalettePresentationModel
    ) {
        syncSelectionAnchor(resultIDs: cachedResults.map(\.id), presentation: presentation)
    }

    /// Anchors the selection from the currently visible results.
    public func syncSelectionAnchorFromVisibleResults(
        presentation: CommandPalettePresentationModel
    ) {
        syncSelectionAnchor(resultIDs: visibleResults.map(\.id), presentation: presentation)
    }

    /// Projects the current palette contents into a debug snapshot for the
    /// per-window automation/debug surface, or the empty snapshot when the
    /// palette is not presented. The mode label and matching query are resolved
    /// app-side and passed in.
    public func debugSnapshot(
        isPresented: Bool,
        mode: String,
        queryForMatching: String
    ) -> CommandPaletteDebugSnapshot {
        guard isPresented else { return .empty }

        let rows = Array(visibleResults.prefix(20)).map { result in
            CommandPaletteDebugResultRow(
                commandId: result.command.id,
                title: result.command.title,
                shortcutHint: result.command.shortcutHint,
                trailingLabel: renderTrailingLabel(for: result.command)?.text,
                score: result.score
            )
        }

        return CommandPaletteDebugSnapshot(
            query: queryForMatching,
            mode: mode,
            results: rows
        )
    }
}
