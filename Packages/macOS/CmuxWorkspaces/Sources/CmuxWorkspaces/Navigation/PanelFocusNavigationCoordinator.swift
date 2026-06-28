public import Foundation
public import Bonsplit

/// Orchestrates pane/surface focus navigation for a workspace: Cmd-arrow
/// move-focus across split panes, and next/previous/index/last surface selection
/// within the focused pane.
///
/// Faithful lift of the `Workspace` bonsplit-navigation methods
/// (`moveFocus(direction:)`, `selectNextSurface`, `selectPreviousSurface`,
/// `selectSurface(at:)`, `selectLastSurface`): the canvas-vs-splits branch, the
/// unfocus-previous-then-navigate ordering, and the read-mutate-reconcile shape
/// (read the focused pane's selected tab after a focus/tab mutation and run
/// `applyTabSelection` to align AppKit first responder). The primitives that
/// touch app-target types (the `BonsplitController`, the `any Panel` registry's
/// `unfocus()`, the `applyTabSelection` chain, the canvas model) stay app-side
/// behind ``PanelFocusNavigationHosting``; this coordinator never names one.
///
/// **Isolation design.** `@MainActor`, not an actor. Every entry point already
/// ran on the main actor: these methods are invoked from keyboard shortcuts, the
/// command palette, and the CLI, and they read and mutate AppKit/bonsplit state
/// synchronously within one turn. Co-locating this orchestration with its callers
/// turns every bridge into a plain call; an actor here would manufacture an
/// isolation domain the design immediately re-enters. The host is held weakly:
/// `Workspace` owns this coordinator, so a strong back-reference would be a
/// retain cycle.
@MainActor
public final class PanelFocusNavigationCoordinator {
    private weak var host: (any PanelFocusNavigationHosting)?

    /// Reentrancy latch for ``reconcileFocusState()`` (legacy
    /// `Workspace.isReconcilingFocusState`): the reconcile mutates bonsplit focus
    /// and panel focus, which can feed back into another reconcile; this guards
    /// against re-entering while a reconcile is in flight.
    private var isReconcilingFocusState = false

    /// Coalesce latch for ``scheduleFocusReconcile()`` (legacy
    /// `Workspace.focusReconcileScheduled`): collapses a burst of schedule
    /// requests within one turn into a single deferred reconcile.
    private var focusReconcileScheduled = false

    /// Creates the coordinator. Call ``attach(host:)`` before use.
    public init() {}

    /// Wires the app-side host the navigation drives through. Held weakly.
    public func attach(host: any PanelFocusNavigationHosting) {
        self.host = host
    }

    // MARK: - Pane focus

    /// Moves keyboard focus to the adjacent pane in `direction`, unfocusing the
    /// previously focused panel first and reconciling tab selection after. Legacy
    /// `Workspace.moveFocus(direction:)`.
    public func moveFocus(direction: NavigationDirection) {
        guard let host else { return }
        if host.panelFocusNavIsCanvasLayout {
            host.panelFocusNavMoveCanvasFocus(direction: direction)
            return
        }
        let previousFocusedPanelId = host.panelFocusNavFocusedPanelId

        // Unfocus the currently-focused panel before navigating.
        if let prevPanelId = previousFocusedPanelId {
            host.panelFocusNavUnfocusPanel(panelId: prevPanelId)
        }

        host.panelFocusNavNavigateFocus(direction: direction)

        // Always reconcile selection/focus after navigation so AppKit first-responder and
        // bonsplit's focused pane stay aligned, even through split tree mutations.
        reconcileFocusedPaneSelection(host: host)
    }

    // MARK: - Surface Navigation

    /// Select the next surface in the currently focused pane. Legacy
    /// `Workspace.selectNextSurface()`.
    public func selectNextSurface() {
        guard let host else { return }
        if host.panelFocusNavIsCanvasLayout, host.panelFocusNavSelectAdjacentCanvasTab(offset: 1) { return }
        host.panelFocusNavSelectNextTab()
        reconcileFocusedPaneSelection(host: host)
    }

    /// Select the previous surface in the currently focused pane. Legacy
    /// `Workspace.selectPreviousSurface()`.
    public func selectPreviousSurface() {
        guard let host else { return }
        if host.panelFocusNavIsCanvasLayout, host.panelFocusNavSelectAdjacentCanvasTab(offset: -1) { return }
        host.panelFocusNavSelectPreviousTab()
        reconcileFocusedPaneSelection(host: host)
    }

    /// Select a surface by index in the currently focused pane. Legacy
    /// `Workspace.selectSurface(at:)`.
    public func selectSurface(at index: Int) {
        guard let host else { return }
        guard let focusedPaneId = host.panelFocusNavFocusedPaneId else { return }
        let tabIds = host.panelFocusNavTabIds(inPane: focusedPaneId)
        guard index >= 0 && index < tabIds.count else { return }
        host.panelFocusNavSelectTab(tabIds[index])

        if let tabId = host.panelFocusNavSelectedTabId(inPane: focusedPaneId) {
            host.panelFocusNavApplyTabSelection(tabId: tabId, inPane: focusedPaneId)
        }
    }

    /// Select the last surface in the currently focused pane. Legacy
    /// `Workspace.selectLastSurface()`.
    public func selectLastSurface() {
        guard let host else { return }
        guard let focusedPaneId = host.panelFocusNavFocusedPaneId else { return }
        let tabIds = host.panelFocusNavTabIds(inPane: focusedPaneId)
        guard let last = tabIds.last else { return }
        host.panelFocusNavSelectTab(last)

        if let tabId = host.panelFocusNavSelectedTabId(inPane: focusedPaneId) {
            host.panelFocusNavApplyTabSelection(tabId: tabId, inPane: focusedPaneId)
        }
    }

    // MARK: - Panel focus decision

    /// Computes the pure pane/convergence decision for one
    /// `Workspace.focusPanel(_:trigger:focusIntent:)` turn (legacy
    /// `focusPanel`'s `targetPaneId`/`selectionAlreadyConverged`/
    /// `shouldSuppressReentrantRefocus` locals).
    ///
    /// The app-side `focusPanel` keeps every effect: the `PanelFocusIntent`
    /// resolution (`focusIntent ?? panel.preferredFocusIntentForActivation()`),
    /// the live `bonsplitController.focusPane`/`selectTab`, `applyTabSelection`,
    /// the layout follow-up, browser address-bar autofocus, unread-badge sync,
    /// and `markExplicitFocusIntent`. It calls this only to resolve which pane
    /// owns `tabId` and whether the live selection has already converged, so the
    /// split-tree scan and the convergence/suppression math live in one place.
    ///
    /// `isTerminalFirstResponderTrigger` and
    /// `targetHasPendingReparentSuppression` are precomputed app-side (the latter
    /// from the target terminal's AppKit hosted view) so no `FocusPanelTrigger`
    /// or AppKit type crosses the seam. Returns a converged-`false`, `nil`-pane
    /// decision when no host is attached, matching the legacy early reads against
    /// an empty split tree.
    public func panelFocusDecision(
        forTabId tabId: TabID,
        isTerminalFirstResponderTrigger: Bool,
        targetHasPendingReparentSuppression: Bool
    ) -> PanelFocusDecision {
        guard let host else {
            return PanelFocusDecision(
                targetPaneId: nil,
                selectionAlreadyConverged: false,
                targetHasPendingReparentSuppression: targetHasPendingReparentSuppression,
                shouldSuppressReentrantRefocus: false
            )
        }

        // `selectTab` does not necessarily move bonsplit's focused pane. Resolve the pane that owns
        // the target tab so the app-side `focusPanel` can make it focused if needed.
        let targetPaneId = host.panelFocusNavAllPaneIds.first(where: { paneId in
            host.panelFocusNavTabIds(inPane: paneId).contains(where: { $0 == tabId })
        })
        let selectionAlreadyConverged: Bool = {
            guard let targetPaneId else { return false }
            return host.panelFocusNavFocusedPaneId == targetPaneId &&
                host.panelFocusNavSelectedTabId(inPane: targetPaneId) == tabId
        }()
        let shouldSuppressReentrantRefocus =
            isTerminalFirstResponderTrigger &&
            selectionAlreadyConverged &&
            targetHasPendingReparentSuppression

        return PanelFocusDecision(
            targetPaneId: targetPaneId,
            selectionAlreadyConverged: selectionAlreadyConverged,
            targetHasPendingReparentSuppression: targetHasPendingReparentSuppression,
            shouldSuppressReentrantRefocus: shouldSuppressReentrantRefocus
        )
    }

    // MARK: - Post-close focus convergence

    /// Resolves which tab `Workspace.closePanel(_:force:)` should close when the
    /// panel→surface mapping has transiently drifted during a split-tree mutation
    /// (legacy `closePanel`'s focused-pane fallback). When the target panel is the
    /// active one (`targetIsActive`, precomputed app-side from `focusedPanelId` and
    /// the AppKit first-responder terminal), the tab to close is whichever tab
    /// bonsplit marks selected in the focused pane.
    ///
    /// `targetIsActive` is passed in because it reads `focusedPanelId` plus the
    /// AppKit key/main-window first responder, neither of which the package can
    /// name. Returns `nil` (skip the fallback close, legacy `return false`) when the
    /// target is not active, no pane is focused, or the focused pane has no selected
    /// tab. The app-side `closePanel` keeps the DEBUG skip/fallback logging and the
    /// `requestCloseTab` effect; this only owns the snapshot decision.
    public func resolveCloseFallbackTarget(targetIsActive: Bool) -> TabID? {
        guard let host else { return nil }
        guard targetIsActive,
              let focusedPane = host.panelFocusNavFocusedPaneId,
              let selected = host.panelFocusNavSelectedTabId(inPane: focusedPane) else {
            return nil
        }
        return selected
    }

    /// Converges tab selection after a close, the shared post-close decision in
    /// `Workspace`'s `didCloseTab`/`didClosePane` bonsplit delegate callbacks.
    ///
    /// Prefers `preferredSelectTabId` (didCloseTab's staged
    /// `consumePostCloseSelectTabId`) when it still lives in `preferredPane` and
    /// that pane is focused, selecting and applying it in the same close
    /// transaction so the pane never shows a transient frame with no selected
    /// content. Otherwise re-applies whatever bonsplit now reports as the focused
    /// pane's selection (closing the last tab in a pane can move focus and skip
    /// `didSelectTab`, so sidebar state must be re-synced). When no focused
    /// selection exists and `scheduleReconcileWhenNoFocusedSelection` is true
    /// (didClosePane's `shouldScheduleFocusReconcile`), falls back to a coalesced
    /// focus reconcile.
    ///
    /// didCloseTab passes the staged tab + its pane with the reconcile fallback
    /// off (it schedules the reconcile unconditionally later, gated on
    /// `!isDetaching`); didClosePane passes `nil`/`nil` with the fallback on. All
    /// effects route through ``PanelFocusNavigationHosting`` witnesses, so no
    /// `BonsplitController` or `applyTabSelection` chain crosses into the package.
    public func reapplyFocusedSelectionAfterClose(
        preferredSelectTabId: TabID?,
        preferredPane: PaneID?,
        scheduleReconcileWhenNoFocusedSelection: Bool
    ) {
        guard let host else { return }

        if let preferredSelectTabId,
           let preferredPane,
           host.panelFocusNavAllPaneIds.contains(preferredPane),
           host.panelFocusNavTabIds(inPane: preferredPane).contains(where: { $0 == preferredSelectTabId }),
           host.panelFocusNavFocusedPaneId == preferredPane {
            host.panelFocusNavSelectTab(preferredSelectTabId)
            host.panelFocusNavApplyTabSelection(tabId: preferredSelectTabId, inPane: preferredPane)
            return
        }

        if let focusedPane = host.panelFocusNavFocusedPaneId,
           let focusedTabId = host.panelFocusNavSelectedTabId(inPane: focusedPane) {
            host.panelFocusNavApplyTabSelection(tabId: focusedTabId, inPane: focusedPane)
        } else if scheduleReconcileWhenNoFocusedSelection {
            scheduleFocusReconcile()
        }
    }

    // MARK: - Reconcile

    /// Re-reads the focused pane's selected tab and runs the `applyTabSelection`
    /// chain, the shared tail of `moveFocus`/`selectNextSurface`/
    /// `selectPreviousSurface` (each of which re-reads `focusedPaneId` after the
    /// mutation rather than reusing a captured id).
    private func reconcileFocusedPaneSelection(host: any PanelFocusNavigationHosting) {
        if let paneId = host.panelFocusNavFocusedPaneId,
           let tabId = host.panelFocusNavSelectedTabId(inPane: paneId) {
            host.panelFocusNavApplyTabSelection(tabId: tabId, inPane: paneId)
        }
    }

    // MARK: - Focus-state reconcile

    /// Converges AppKit first responder and panel focus onto the model source of
    /// truth (the bonsplit focused pane + selected tab). Legacy
    /// `Workspace.reconcileFocusState()`: reentrancy-guarded, inert while portal
    /// rendering is disabled, and falling back to the first registered panel when
    /// no pane resolves to a live panel.
    public func reconcileFocusState() {
        guard let host else { return }
        guard host.panelFocusNavPortalRenderingEnabled else { return }
        guard !isReconcilingFocusState else { return }
        isReconcilingFocusState = true
        defer { isReconcilingFocusState = false }

        // Source of truth: bonsplit focused pane + selected tab.
        // AppKit first responder must converge to this model state, not the other way around.
        var targetPanelId: UUID?

        if let focusedPane = host.panelFocusNavFocusedPaneId,
           let focusedTabId = host.panelFocusNavSelectedTabId(inPane: focusedPane),
           let mappedPanelId = host.panelFocusNavPanelId(fromSurfaceId: focusedTabId),
           host.panelFocusNavPanelExists(panelId: mappedPanelId) {
            targetPanelId = mappedPanelId
        } else {
            for pane in host.panelFocusNavAllPaneIds {
                guard let selectedTabId = host.panelFocusNavSelectedTabId(inPane: pane),
                      let mappedPanelId = host.panelFocusNavPanelId(fromSurfaceId: selectedTabId),
                      host.panelFocusNavPanelExists(panelId: mappedPanelId) else { continue }
                host.panelFocusNavFocusPane(pane)
                host.panelFocusNavSelectTab(selectedTabId)
                targetPanelId = mappedPanelId
                break
            }
        }

        if targetPanelId == nil, let fallbackPanelId = host.panelFocusNavAllPanelIds.first {
            targetPanelId = fallbackPanelId
            if let fallbackTabId = host.panelFocusNavSurfaceId(fromPanelId: fallbackPanelId),
               let fallbackPane = host.panelFocusNavAllPaneIds.first(where: { paneId in
                   host.panelFocusNavTabIds(inPane: paneId).contains(where: { $0 == fallbackTabId })
               }) {
                host.panelFocusNavFocusPane(fallbackPane)
                host.panelFocusNavSelectTab(fallbackTabId)
            }
        }

        guard let targetPanelId, host.panelFocusNavPanelExists(panelId: targetPanelId) else { return }

        host.panelFocusNavUnfocusAllExcept(panelId: targetPanelId)

        host.panelFocusNavFocusPanel(panelId: targetPanelId)
        host.panelFocusNavEnsureTerminalFocus(panelId: targetPanelId)
        host.panelFocusNavApplyFocusedPanelDirectory(panelId: targetPanelId)
        host.panelFocusNavApplyFocusedPanelGitBranch(panelId: targetPanelId)
        host.panelFocusNavApplyFocusedPanelPullRequest(panelId: targetPanelId)
    }

    /// Reconcile focus/first-responder convergence.
    /// Coalesce to the next main-queue turn so bonsplit selection/pane mutations settle first.
    /// Legacy `Workspace.scheduleFocusReconcile()`.
    public func scheduleFocusReconcile() {
        guard let host else { return }
        guard host.panelFocusNavPortalRenderingEnabled else { return }
        host.panelFocusNavNoteScheduleDuringDetach()
        guard !focusReconcileScheduled else { return }
        focusReconcileScheduled = true
        host.panelFocusNavScheduleAfterCurrentTurn { [weak self] in
            guard let self else { return }
            guard let host = self.host else { return }
            guard host.panelFocusNavPortalRenderingEnabled else {
                self.focusReconcileScheduled = false
                return
            }
            self.focusReconcileScheduled = false
            self.reconcileFocusState()
        }
    }

    // MARK: - Non-focus-split focus preservation

    /// Preserves keyboard focus on `preferredPanelId` after a split that did not
    /// take focus intent (legacy `Workspace.preserveFocusAfterNonFocusSplit`).
    ///
    /// Bonsplit's `splitPane` focuses the newly created pane and may emit one
    /// delayed didSelect/didFocus callback, so this re-asserts focus over three
    /// main-queue turns: once synchronously, then on the next two turns. The
    /// generation token (held app-side in `SurfaceRegistryModel`) lets a
    /// superseding split cancel the pending reasserts. When `preferredPanelId` is
    /// nil or already gone, it clears any pending request and schedules a plain
    /// focus reconcile instead.
    ///
    /// `previousHostedView` is the pre-split focused terminal's AppKit hosted
    /// view, captured by the split-creation caller before bonsplit mutates
    /// focus; it crosses the seam opaquely as `AnyObject?` and is forwarded only
    /// on the first (synchronous) reassert (`allowPreviousHostedView: true`),
    /// matching the legacy ordering.
    public func preserveFocusAfterNonFocusSplit(
        preferredPanelId: UUID?,
        splitPanelId: UUID,
        previousHostedView: AnyObject?
    ) {
        guard let host else { return }
        guard let preferredPanelId, host.panelFocusNavPanelExists(panelId: preferredPanelId) else {
            host.panelFocusNavClearNonFocusSplitFocusReassert(generation: nil)
            scheduleFocusReconcile()
            return
        }

        let generation = host.panelFocusNavBeginNonFocusSplitFocusReassert(
            preferredPanelId: preferredPanelId,
            splitPanelId: splitPanelId
        )

        // Bonsplit splitPane focuses the newly created pane and may emit one delayed
        // didSelect/didFocus callback. Re-assert focus over multiple turns so model
        // focus and AppKit first responder stay aligned with non-focus-intent splits.
        reassertFocusAfterNonFocusSplit(
            generation: generation,
            preferredPanelId: preferredPanelId,
            splitPanelId: splitPanelId,
            previousHostedView: previousHostedView,
            allowPreviousHostedView: true
        )

        host.panelFocusNavScheduleAfterCurrentTurn { [weak self] in
            guard let self else { return }
            self.reassertFocusAfterNonFocusSplit(
                generation: generation,
                preferredPanelId: preferredPanelId,
                splitPanelId: splitPanelId,
                previousHostedView: previousHostedView,
                allowPreviousHostedView: false
            )

            guard let host = self.host else { return }
            host.panelFocusNavScheduleAfterCurrentTurn { [weak self] in
                guard let self else { return }
                self.reassertFocusAfterNonFocusSplit(
                    generation: generation,
                    preferredPanelId: preferredPanelId,
                    splitPanelId: splitPanelId,
                    previousHostedView: previousHostedView,
                    allowPreviousHostedView: false
                )
                self.scheduleFocusReconcile()
                self.host?.panelFocusNavClearNonFocusSplitFocusReassert(generation: generation)
            }
        }
    }

    /// One reassert turn for ``preserveFocusAfterNonFocusSplit``: re-runs
    /// `focusPanel` (or terminal first-responder convergence) only while the
    /// pending request still matches `generation` and the preferred panel still
    /// exists (legacy `Workspace.reassertFocusAfterNonFocusSplit`). A stale
    /// generation no-ops; a vanished panel clears the request.
    private func reassertFocusAfterNonFocusSplit(
        generation: UInt64,
        preferredPanelId: UUID,
        splitPanelId: UUID,
        previousHostedView: AnyObject?,
        allowPreviousHostedView: Bool
    ) {
        guard let host else { return }
        guard host.panelFocusNavMatchesPendingNonFocusSplitFocusReassert(
            generation: generation,
            preferredPanelId: preferredPanelId,
            splitPanelId: splitPanelId
        ) else {
            return
        }

        guard host.panelFocusNavPanelExists(panelId: preferredPanelId) else {
            host.panelFocusNavClearNonFocusSplitFocusReassert(generation: generation)
            return
        }

        if host.panelFocusNavFocusedPanelId == splitPanelId {
            host.panelFocusNavReassertFocusPanel(
                panelId: preferredPanelId,
                previousHostedView: allowPreviousHostedView ? previousHostedView : nil
            )
            return
        }

        guard host.panelFocusNavFocusedPanelId == preferredPanelId else { return }
        host.panelFocusNavEnsureTerminalFocus(panelId: preferredPanelId)
    }
}
