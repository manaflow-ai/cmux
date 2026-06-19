public import Foundation
import Observation

/// Per-window focused-surface bookkeeping plus the deferred previous-workspace
/// unfocus state machine that `TabManager` used to keep inline.
///
/// It owns two pieces of window-scoped state: `lastFocusedPanelByTab` (the
/// per-workspace remembered focused panel used to restore focus on workspace
/// switch) and `pendingWorkspaceUnfocusTarget` (the single deferred unfocus
/// awaiting ContentView's handoff-completion signal).
///
/// `@MainActor` because every entry point is a MainActor UI path (the
/// selection `didSet`-driven focus restore, and ContentView's handoff/timeout
/// callbacks). Reads and writes go through ``FocusedSurfaceHosting``
/// synchronously inside one turn, preserving the legacy interleavings exactly:
/// `focusSelectedWorkspacePanel` synchronously stores a pending target, may
/// synchronously flush a stale one, and then focuses the restored panel, which
/// re-enters the window through the panel-focus path. State therefore lives on
/// one isolation domain. Bodies are lifted one-for-one from
/// `Sources/TabManager.swift`; only the host-seam spellings and the
/// DEBUG-trace hand-off changed.
@MainActor
@Observable
public final class FocusedSurfaceModel {
    @ObservationIgnored
    private weak var host: (any FocusedSurfaceHosting)?

    /// Per-workspace remembered focused panel id (legacy
    /// `lastFocusedPanelByTab`).
    private var lastFocusedPanelByTab: [UUID: UUID] = [:]

    /// The single deferred previous-workspace unfocus awaiting handoff
    /// completion (legacy `pendingWorkspaceUnfocusTarget`).
    private var pendingWorkspaceUnfocusTarget: (tabId: UUID, panelId: UUID)?

    /// Creates a detached model; call ``attach(host:)`` before use.
    public init() {}

    /// Wires the window-side host. Held weakly: the host (the per-window
    /// `TabManager`) owns this model, so a strong back-reference would
    /// retain-cycle.
    public func attach(host: any FocusedSurfaceHosting) {
        self.host = host
    }

    // MARK: - Remembered focused panel

    /// Remembers the focused surface for the workspace (legacy
    /// `rememberFocusedSurface`).
    public func rememberFocusedSurface(workspaceId: UUID, surfaceId: UUID) {
        lastFocusedPanelByTab[workspaceId] = surfaceId
    }

    /// The window-level remembered focused panel for the workspace, if any.
    /// Used by the focus-history resolution fallback chain.
    public func rememberedFocusedPanelId(_ workspaceId: UUID) -> UUID? {
        lastFocusedPanelByTab[workspaceId]
    }

    /// Records the previous selection's focused panel before it is replaced
    /// (legacy selection-`didSet` `lastFocusedPanelByTab[previous] = …`).
    public func recordRememberedFocusForPreviousSelection(_ workspaceId: UUID) {
        if let panelId = host?.workspaceFocusedPanelId(workspaceId) {
            lastFocusedPanelByTab[workspaceId] = panelId
        }
    }

    /// Drops the workspace's remembered focus (legacy
    /// `lastFocusedPanelByTab.removeValue(forKey:)` on workspace removal).
    public func forgetRememberedFocus(workspaceId: UUID) {
        lastFocusedPanelByTab.removeValue(forKey: workspaceId)
    }

    /// Clears all window-scoped focused-surface state (the window-reset path:
    /// legacy `lastFocusedPanelByTab.removeAll()` +
    /// `pendingWorkspaceUnfocusTarget = nil`).
    public func reset() {
        lastFocusedPanelByTab.removeAll()
        pendingWorkspaceUnfocusTarget = nil
    }

    // MARK: - Focus restore on selection change

    /// Restores focus to the selected workspace's panel, deferring the
    /// previous workspace's unfocus until ContentView confirms handoff
    /// completion (legacy `focusSelectedTabPanel(previousTabId:)`).
    public func focusSelectedWorkspacePanel(previousWorkspaceId: UUID?) {
        guard let host, let selectedWorkspaceId = host.selectedWorkspaceId else { return }

        let panelId: UUID
        if let restoredPanelId = lastFocusedPanelByTab[selectedWorkspaceId],
           host.panelExists(workspaceId: selectedWorkspaceId, panelId: restoredPanelId) {
            panelId = restoredPanelId
        } else if let focusedPanelId = host.workspaceFocusedPanelId(selectedWorkspaceId),
                  host.panelExists(workspaceId: selectedWorkspaceId, panelId: focusedPanelId) {
            panelId = focusedPanelId
        } else {
            return
        }

        // Defer unfocusing the previous workspace's panel until ContentView confirms handoff
        // completion (new workspace has focus or timeout fallback), to avoid a visible freeze gap.
        if let previousWorkspaceId,
           let previousPanelId = host.workspaceFocusedPanelId(previousWorkspaceId),
           host.panelExists(workspaceId: previousWorkspaceId, panelId: previousPanelId) {
            replacePendingWorkspaceUnfocusTarget(
                with: (tabId: previousWorkspaceId, panelId: previousPanelId)
            )
        }

        // Route workspace reactivation through the normal focus machinery so panel-local
        // activation intents like browser find-field focus are restored on return.
        host.focusPanel(workspaceId: selectedWorkspaceId, panelId: panelId)
    }

    // MARK: - Deferred unfocus state machine

    /// Completes the deferred previous-workspace unfocus once handoff finishes
    /// (legacy `completePendingWorkspaceUnfocus(reason:)`).
    public func completePendingWorkspaceUnfocus(reason: String) {
        guard let host, let pending = pendingWorkspaceUnfocusTarget else { return }
        // If this tab became selected again before handoff completion, drop the stale
        // pending entry so it cannot be flushed later and deactivate the selected workspace.
        guard Self.shouldUnfocusPendingWorkspace(
            pendingTabId: pending.tabId,
            selectedTabId: host.selectedWorkspaceId
        ) else {
            pendingWorkspaceUnfocusTarget = nil
            host.logPendingWorkspaceUnfocusEvent(
                .droppedSelectedAgain(workspaceId: pending.tabId, panelId: pending.panelId)
            )
            return
        }
        pendingWorkspaceUnfocusTarget = nil
        unfocusWorkspacePanel(tabId: pending.tabId, panelId: pending.panelId)
        host.logPendingWorkspaceUnfocusEvent(
            .completed(workspaceId: pending.tabId, panelId: pending.panelId, reason: reason)
        )
    }

    private func replacePendingWorkspaceUnfocusTarget(with next: (tabId: UUID, panelId: UUID)) {
        guard let host else { return }
        if let current = pendingWorkspaceUnfocusTarget,
           current.tabId == next.tabId,
           current.panelId == next.panelId {
            return
        }

        if let current = pendingWorkspaceUnfocusTarget {
            // Never unfocus the currently selected workspace when replacing stale pending state.
            if Self.shouldUnfocusPendingWorkspace(
                pendingTabId: current.tabId,
                selectedTabId: host.selectedWorkspaceId
            ) {
                unfocusWorkspacePanel(tabId: current.tabId, panelId: current.panelId)
                host.logPendingWorkspaceUnfocusEvent(
                    .flushedOnReplace(workspaceId: current.tabId, panelId: current.panelId)
                )
            } else {
                host.logPendingWorkspaceUnfocusEvent(
                    .droppedOnReplaceSelected(workspaceId: current.tabId, panelId: current.panelId)
                )
            }
        }

        pendingWorkspaceUnfocusTarget = next
        host.logPendingWorkspaceUnfocusEvent(
            .deferred(workspaceId: next.tabId, panelId: next.panelId)
        )
    }

    private func unfocusWorkspacePanel(tabId: UUID, panelId: UUID) {
        host?.unfocusPanel(workspaceId: tabId, panelId: panelId)
    }

    /// Whether a pending workspace unfocus should fire: only when the pending
    /// workspace is no longer the selected one (legacy
    /// `selectedTabId != pendingTabId`).
    public static func shouldUnfocusPendingWorkspace(pendingTabId: UUID, selectedTabId: UUID?) -> Bool {
        selectedTabId != pendingTabId
    }
}
