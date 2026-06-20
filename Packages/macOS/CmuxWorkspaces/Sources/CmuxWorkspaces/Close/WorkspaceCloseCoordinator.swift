public import Foundation
public import CmuxSettings

/// Computes the pure close-planning half of the window's workspace-close
/// flows over the window's `WorkspacesModel`: which workspaces are closable in
/// sidebar order, the sidebar-selected subset in sidebar order, and the
/// confirmation `WorkspaceClosePlan` (title/message/acceptCmdD). The plan is a
/// pure function of the model snapshot plus the localized strings the app
/// supplies through ``CloseConfirming``.
///
/// The confirmation-presentation half — the `NSAlert` presentation itself plus
/// the `closeWorkspaceIfRunningProcess` / `closeWorkspacesWithConfirmation`
/// dialog routing — stays in the window-side `TabManager`, which owns those
/// AppKit collaborators. This split lifts the legacy `orderedClosableWorkspaces`,
/// `orderedSidebarSelectedWorkspaceIds`, `closeWorkspacesPlan(for:)`, and
/// `closeWorkspaceDisplayTitle` planning bodies AND the
/// `closeWorkspace`/`detachWorkspace`/`attachWorkspace` lifecycle-execution
/// orchestration out of the god file one-for-one, making the close sequence
/// machine-diffable and unit-testable.
///
/// The execution methods own the orchestration that is pure over the
/// ``WorkspacesModel`` (the remaining-count guard, `tabs` removal/insertion, the
/// group dissolve and contiguity normalization, the selection-after-close index
/// math) and invert every concrete teardown effect through
/// ``WorkspaceCloseHosting``. The interleave order of model mutations and host
/// effects is the observable behavior, lifted byte-for-byte from the legacy
/// bodies.
@MainActor
public final class WorkspaceCloseCoordinator<Tab: WorkspaceTabRepresenting> {
    private let model: WorkspacesModel<Tab>
    private weak var confirming: (any CloseConfirming)?
    private weak var host: (any WorkspaceCloseHosting<Tab>)?
    private var closeTabWarning: (any CloseTabWarningReading)?

    /// Creates the coordinator over the window's workspace model.
    public init(model: WorkspacesModel<Tab>) {
        self.model = model
    }

    /// Attaches the window-side confirmation seam (the localized-string and
    /// alert-presenting half the app target owns).
    public func attach(confirming: any CloseConfirming) {
        self.confirming = confirming
    }

    /// Attaches the close-tab warning settings the confirmation decision routes
    /// through. The app target supplies the live ``CloseTabWarningReading``
    /// (its `CloseTabWarningStore`); tests inject a fixed fake.
    public func attach(closeTabWarning: any CloseTabWarningReading) {
        self.closeTabWarning = closeTabWarning
    }

    /// Whether a close request from `source` should present the confirmation
    /// dialog, given the caller's per-tab `requiresConfirmation` state. Lifts
    /// the legacy private `TabManager.shouldConfirmClose(requiresConfirmation:source:)`
    /// one-for-one: a `.workspace` close honours `requiresConfirmation`
    /// directly, while `.tabClose` / `.tabCloseButton` route through the
    /// ``CloseTabWarningReading`` policy for the close-shortcut / X-button
    /// warning toggles.
    ///
    /// Returns `requiresConfirmation` unchanged when the warning seam has not
    /// been attached (only reachable before wiring, where the legacy code never
    /// asked); the window wires it at construction.
    public func shouldConfirmClose(
        requiresConfirmation: Bool,
        source: CloseConfirmationSource
    ) -> Bool {
        switch source {
        case .workspace:
            return requiresConfirmation
        case .tabClose:
            return closeTabWarning?.shouldConfirmClose(
                requiresConfirmation: requiresConfirmation,
                source: .shortcut
            ) ?? requiresConfirmation
        case .tabCloseButton:
            return closeTabWarning?.shouldConfirmClose(
                requiresConfirmation: requiresConfirmation,
                source: .tabCloseButton
            ) ?? requiresConfirmation
        }
    }

    /// Attaches the window-side teardown-effect seam (the `Workspace`/`AppDelegate`
    /// reach the close/detach/attach orchestration inverts through).
    public func attach(host: any WorkspaceCloseHosting<Tab>) {
        self.host = host
    }

    /// The workspaces matching `workspaceIds`, returned in the model's sidebar
    /// order and filtered to those actually closable (pinned excluded unless
    /// `allowPinned`). Legacy `orderedClosableWorkspaces(_:allowPinned:)`.
    public func orderedClosableWorkspaces(_ workspaceIds: [UUID], allowPinned: Bool) -> [Tab] {
        let targetIds = Set(workspaceIds)
        return model.tabs.compactMap { workspace in
            guard targetIds.contains(workspace.id) else { return nil }
            guard allowPinned || !workspace.isPinned else { return nil }
            return workspace
        }
    }

    /// The intersection of `sidebarSelectedWorkspaceIds` with the window's
    /// workspaces, returned in sidebar order. Legacy
    /// `orderedSidebarSelectedWorkspaceIds()`.
    public func orderedSidebarSelectedWorkspaceIds(
        sidebarSelectedWorkspaceIds: Set<UUID>
    ) -> [UUID] {
        model.tabs.compactMap { workspace in
            sidebarSelectedWorkspaceIds.contains(workspace.id) ? workspace.id : nil
        }
    }

    /// Builds the confirmation plan for closing `workspaces`. Pure assembly of
    /// the legacy `closeWorkspacesPlan(for:)`: the title/message come from the
    /// app's localized catalog (through ``CloseConfirming``), and `acceptCmdD`
    /// / `willCloseWindow` is true exactly when the batch closes every
    /// workspace in the window.
    ///
    /// Returns `nil` only when the confirmation seam has not been attached; the
    /// window-side caller never reaches planning before wiring it.
    public func closeWorkspacesPlan(for workspaces: [Tab]) -> WorkspaceClosePlan? {
        guard let confirming else { return nil }
        let willCloseWindow = workspaces.count == model.tabs.count
        let title = confirming.closeWorkspacesTitle(willCloseWindow: willCloseWindow)
        let bulletedTitles = workspaces
            .map { "• \(closeWorkspaceDisplayTitle($0.title))" }
            .joined(separator: "\n")
        let message = confirming.closeWorkspacesMessage(
            willCloseWindow: willCloseWindow,
            workspaceCount: workspaces.count,
            bulletedTitles: bulletedTitles
        )
        return WorkspaceClosePlan(
            workspaceIds: workspaces.map(\.id),
            willCloseWindow: willCloseWindow,
            title: title,
            message: message,
            acceptCmdD: willCloseWindow
        )
    }

    /// Collapses a workspace title to a single confirmation-list line, falling
    /// back to the localized "Workspace" name when empty. Legacy
    /// `closeWorkspaceDisplayTitle(_:)`.
    public func closeWorkspaceDisplayTitle(_ title: String?) -> String {
        let collapsed = title?
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let collapsed, !collapsed.isEmpty {
            return collapsed
        }
        return confirming?.workspaceDisplayTitleFallback ?? ""
    }

    // MARK: - Lifecycle execution (legacy closeWorkspace / detachWorkspace / attachWorkspace)

    /// Closes `workspace`, removing it from the window and running the full
    /// teardown sequence. Lifts the legacy `TabManager.closeWorkspace(_:recordHistory:)`
    /// body one-for-one: the remaining-count guard, breadcrumb, remote-tmux kill,
    /// closed-item history push, probe/selection/focus-history clears, panel and
    /// remote-connection teardown, browser unwire, group dissolve, and the
    /// selection-after-close index math, in that exact order. Model mutations
    /// (`tabs`, `selectedTabId`, `dissolveGroupsAnchoredBy`) run here over the
    /// model; every app-coupled effect inverts through ``WorkspaceCloseHosting``.
    ///
    /// No-op when the host is unattached (the window wires it before any close).
    public func closeWorkspace(_ workspace: Tab, recordHistory: Bool = true) {
        guard let host else { return }
        guard model.tabs.count > 1 else { return }
        host.recordWorkspaceCloseBreadcrumb(remainingTabCount: model.tabs.count - 1)
        // User-initiated close of a mirrored remote tmux session kills it on the
        // remote. (App quit tears down windows without calling closeWorkspace, so
        // quitting still leaves remote sessions alive.)
        if host.isRemoteTmuxMirror(workspace) {
            host.killRemoteTmuxMirror(workspace)
        }
        if recordHistory,
           host.isRestorableInSessionSnapshot(workspace),
           let index = model.tabs.firstIndex(where: { $0.id == workspace.id }) {
            host.recordClosedWorkspaceHistory(workspace, index: index)
        }
        host.clearWorkspaceGitProbes(workspaceId: workspace.id)
        host.clearWorkspacePullRequestTracking(workspaceId: workspace.id)
        host.removeFromSidebarSelection(workspaceId: workspace.id)
        host.invalidateFocusHistoryTarget(workspaceId: workspace.id)

        host.clearNotifications(workspaceId: workspace.id)
        host.teardownAllPanels(workspace)
        host.teardownRemoteConnection(workspace)
        host.unwireClosedBrowserTracking(workspace)
        host.removeClosedBrowserPanels(workspaceId: workspace.id)
        host.clearOwningTabManager(workspace)

        if let index = model.tabs.firstIndex(where: { $0.id == workspace.id }) {
            model.tabs.remove(at: index)
            // Real-close path: if the closed workspace anchored a group, the
            // group dissolves now and its remaining members survive as
            // ungrouped workspaces. This lives at the explicit close site (not
            // in the tabs didSet) so transient remove/insert reorders never
            // trigger dissolve.
            model.dissolveGroupsAnchoredBy(closedWorkspaceId: workspace.id)

            if model.selectedTabId == workspace.id {
                // Keep the "focused index" stable when possible:
                // - If we closed workspace i and there is still a workspace at index i, focus it (the one that moved up).
                // - Otherwise (we closed the last workspace), focus the new last workspace (i-1).
                let newIndex = min(index, max(0, model.tabs.count - 1))
                model.selectedTabId = model.tabs[newIndex].id
            }
        }
        host.publishWorkspaceClosed(workspace)
    }

    /// Detaches `tabId` from this window without closing its panels, returning
    /// the removed workspace. Used by the socket API for cross-window moves.
    /// Lifts the legacy `TabManager.detachWorkspace(tabId:)` body one-for-one.
    ///
    /// No-op (returns `nil`) when the host is unattached or `tabId` is unknown.
    @discardableResult
    public func detachWorkspace(tabId: UUID) -> Tab? {
        guard let host else { return nil }
        guard let index = model.tabs.firstIndex(where: { $0.id == tabId }) else { return nil }
        host.clearWorkspaceGitProbes(workspaceId: tabId)
        host.removeFromSidebarSelection(workspaceId: tabId)
        host.invalidateFocusHistoryTarget(workspaceId: tabId)

        let removed = model.tabs.remove(at: index)
        // Same anchor-close lifecycle as closeWorkspace: detaching a group's
        // anchor dissolves the group; non-anchor members stay in tabs as
        // ungrouped workspaces.
        model.dissolveGroupsAnchoredBy(closedWorkspaceId: removed.id)
        // Clear the detached workspace's own group membership so the
        // destination window — which has no matching WorkspaceGroup — doesn't
        // render it as an orphaned indented row with stale grouping state.
        host.clearGroupMembership(removed)
        host.unwireClosedBrowserTracking(removed)
        host.removeClosedBrowserPanels(workspaceId: removed.id)
        host.clearOwningTabManager(removed)
        host.forgetRememberedFocus(workspaceId: removed.id)

        if model.tabs.isEmpty {
            // The UI assumes each window always has at least one workspace.
            host.addReplacementWorkspaceForEmptyWindow()
            return removed
        }

        if model.selectedTabId == removed.id {
            let nextIndex = min(index, max(0, model.tabs.count - 1))
            model.selectedTabId = model.tabs[nextIndex].id
        }

        return removed
    }

    /// Attaches an existing `workspace` to this window at `index` (appended when
    /// `nil`), selecting it when `select`. Lifts the legacy
    /// `TabManager.attachWorkspace(_:at:select:)` body one-for-one.
    ///
    /// No-op when the host is unattached (the window wires it before any attach).
    public func attachWorkspace(_ workspace: Tab, at index: Int? = nil, select: Bool = true) {
        guard let host else { return }
        host.setOwningTabManager(workspace)
        host.wireClosedBrowserTracking(workspace)
        let insertIndex: Int = {
            guard let index else { return model.tabs.count }
            return max(0, min(index, model.tabs.count))
        }()
        model.tabs.insert(workspace, at: insertIndex)
        // A workspace moved in from another window arrives ungrouped (detach
        // clears `groupId`) and may be pinned, so an arbitrary insert index can
        // split a destination group's contiguous run or drop a pinned workspace
        // below unpinned ones. Re-run the same normalization every insertion
        // path uses so the destination's sidebar invariants — leading pinned
        // segment, contiguous group runs — hold regardless of the drop index.
        model.normalizeWorkspaceGroupContiguity()
        if select {
            model.selectedTabId = workspace.id
        }
    }
}
