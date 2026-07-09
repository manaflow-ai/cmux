import Foundation

/// Present / dismiss / open-request state machine for the per-window command
/// palette, driven on top of a ``CommandPalettePresentationModel`` and reached
/// from the app target through ``CommandPaletteLifecycleHost``.
///
/// These transitions previously lived inline on `ContentView` as
/// `toggleCommandPalette`, `handleCommandPaletteListRequest(scope:)`,
/// `presentCommandPalette(initialQuery:)`, `resetCommandPaletteListState(initialQuery:)`,
/// and the two `dismissCommandPalette` variants. The coordinator now owns the
/// window-agnostic ordering; every app-coupled effect is forwarded through the
/// host so the behavior, including the DEBUG diagnostics, stays byte-faithful.
extension CommandPaletteCoordinator {
    /// Toggles the palette: dismisses it when presented, otherwise presents it in
    /// the commands scope.
    public func toggleCommandPaletteLifecycle<Host: CommandPaletteLifecycleHost>(
        host: Host,
        presentation: CommandPalettePresentationModel
    ) {
        if host.commandPaletteLifecycleIsPresented {
            dismissCommandPalette(
                restoreFocus: true,
                preferredFocusTarget: nil,
                host: host,
                presentation: presentation
            )
        } else {
            presentCommandPalette(
                initialQuery: queryScopePolicy.commandsPrefix,
                host: host,
                presentation: presentation
            )
        }
    }

    /// Handles an open request for `scope`: presents the palette when it is
    /// closed, toggles it closed when the same commands scope is already showing,
    /// otherwise re-seeds the list state for the requested scope.
    public func handleCommandPaletteListRequest<Host: CommandPaletteLifecycleHost>(
        scope: CommandPaletteListScope,
        host: Host,
        presentation: CommandPalettePresentationModel
    ) {
        let initialQuery = (scope == .commands) ? queryScopePolicy.commandsPrefix : ""
        guard host.commandPaletteLifecycleIsPresented else {
            presentCommandPalette(initialQuery: initialQuery, host: host, presentation: presentation)
            return
        }

        if case .commands = presentation.mode,
           queryScopePolicy.listScope(for: presentation.query) == scope {
            dismissCommandPalette(
                restoreFocus: true,
                preferredFocusTarget: nil,
                host: host,
                presentation: presentation
            )
            return
        }

        resetCommandPaletteListState(initialQuery: initialQuery, host: host, presentation: presentation)
    }

    /// Presents the palette: captures the focus-restore target, marks it
    /// presented, resets the probe key and usage history, then seeds the list
    /// state for `initialQuery`.
    public func presentCommandPalette<Host: CommandPaletteLifecycleHost>(
        initialQuery: String,
        host: Host,
        presentation: CommandPalettePresentationModel
    ) {
        host.commandPaletteLifecycleRefreshCachedDefaultTerminalStatus()
        host.commandPaletteLifecycleCaptureFocusRestoreTarget()
        host.commandPaletteLifecycleSetPresented(true)
        host.commandPaletteLifecycleClearForkableProbeActivePanelKey()
        host.commandPaletteLifecycleRefreshUsageHistory()
        resetCommandPaletteListState(initialQuery: initialQuery, host: host, presentation: presentation)
    }

    /// Re-seeds the palette into the commands list mode with `initialQuery`,
    /// clearing drafts/selection/scroll and refreshing results.
    public func resetCommandPaletteListState<Host: CommandPaletteLifecycleHost>(
        initialQuery: String,
        host: Host,
        presentation: CommandPalettePresentationModel
    ) {
        presentation.mode = .commands
        presentation.query = initialQuery
        presentation.renameDraft = ""
        presentation.workspaceDescriptionDraft = ""
        presentation.workspaceDescriptionHeight = host.commandPaletteLifecycleDefaultWorkspaceDescriptionHeight
        presentation.selectedResultIndex = 0
        presentation.selectionAnchorCommandID = nil
        presentation.scrollTargetIndex = nil
        presentation.scrollTargetAnchor = nil
        host.commandPaletteLifecycleSetShouldFocusWorkspaceDescriptionEditor(false)
        host.commandPaletteLifecycleScheduleResultsRefresh(forceSearchCorpusRefresh: true)
        host.commandPaletteLifecycleSyncOverlayCommandListState()
        host.commandPaletteLifecycleResetSearchFocus()
        host.commandPaletteLifecycleSyncDebugState()
    }

    /// Dismisses the palette, tearing down search/probe state and the editor
    /// state machine, then restores focus to `preferredFocusTarget` (or the
    /// captured target) when `restoreFocus` is set.
    public func dismissCommandPalette<Host: CommandPaletteLifecycleHost>(
        restoreFocus: Bool,
        preferredFocusTarget: Host.FocusRestoreTarget?,
        host: Host,
        presentation: CommandPalettePresentationModel
    ) {
        let focusTarget = preferredFocusTarget ?? host.commandPaletteLifecycleCurrentRestoreFocusTarget()
#if DEBUG
        if case .workspaceDescriptionInput(let target) = presentation.mode {
            let newlineCount = presentation.workspaceDescriptionDraft.reduce(into: 0) { count, character in
                if character == "\n" { count += 1 }
            }
            host.commandPaletteLifecycleDebugLog(
                "palette.wsDescription.dismiss workspace=\(target.workspaceId.uuidString.prefix(8)) " +
                "restoreFocus=\(restoreFocus ? 1 : 0) " +
                "draftLen=\((presentation.workspaceDescriptionDraft as NSString).length) " +
                "newlines=\(newlineCount) " +
                "window={\(host.commandPaletteLifecycleObservedWindowDebugSummary())}"
            )
        }
#endif
        host.commandPaletteLifecycleCancelSearch()
        host.commandPaletteLifecycleCancelSearchIndexBuild()
        host.commandPaletteLifecycleCancelForkableAgentAvailabilityProbe()
        host.commandPaletteLifecycleClearForkableProbeActivePanelKey()
        searchRequestID &+= 1
        host.commandPaletteLifecycleSetPresented(false)
        presentation.mode = .commands
        presentation.query = ""
        presentation.renameDraft = ""
        presentation.workspaceDescriptionDraft = ""
        presentation.workspaceDescriptionHeight = host.commandPaletteLifecycleDefaultWorkspaceDescriptionHeight
        presentation.selectedResultIndex = 0
        presentation.selectionAnchorCommandID = nil
        presentation.scrollTargetIndex = nil
        presentation.scrollTargetAnchor = nil
        host.commandPaletteLifecycleSetShouldFocusWorkspaceDescriptionEditor(false)
        host.commandPaletteLifecycleClearSearchFocused()
        host.commandPaletteLifecycleClearRenameFocused()
        host.commandPaletteLifecycleClearRestoreFocusTarget()
        resetSearchCorpus()
        resetResultsPipeline()
        presentation.pendingTextSelectionBehavior = nil
        resolvedSearchRequestID = searchRequestID
        resolvedSearchScope = nil
        resolvedSearchFingerprint = nil
        host.commandPaletteLifecycleClearTerminalOpenTargetAvailability()
        isSearchPending = false
        presentation.pendingActivation = nil
        presentation.resultsRevision &+= 1
        host.commandPaletteLifecycleSyncOverlayCommandListState()
        host.commandPaletteLifecycleClearFirstResponderAndBrowserFocus()
        host.commandPaletteLifecycleSyncDebugState()

        guard restoreFocus, let focusTarget else { return }
        host.commandPaletteLifecycleRequestFocusRestore(target: focusTarget)
    }
}
