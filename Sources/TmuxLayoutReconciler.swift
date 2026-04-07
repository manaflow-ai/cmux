import Foundation

// MARK: - Workspace protocol seam

/// Abstraction over `Workspace` that `TmuxLayoutReconciler` uses to create and
/// close panels. Using a protocol lets unit tests inject a mock without a real
/// `Workspace` instance.
@MainActor
protocol TmuxReconcilerWorkspace: AnyObject {
    /// Create a new terminal split backed by the given tmux pane.
    ///
    /// - Parameters:
    ///   - paneId: The tmux pane identifier, e.g. `"%3"`.
    ///   - windowHint: The tmux window the pane belongs to. The workspace uses
    ///     this to prefer a pending user-initiated panel registered for the same
    ///     window before falling back to any untagged pending panel.
    /// - Returns: The UUID of the newly created (or claimed) panel, or `nil` if
    ///   creation failed (e.g. no suitable source panel is available).
    func newTerminalSplitForTmuxPane(_ paneId: String, windowHint: String) -> UUID?

    /// Close the panel with the given UUID.
    @discardableResult func closePanel(_ panelId: UUID, force: Bool) -> Bool
}

// MARK: - Reconciler

/// Reconciles tmux control mode events with cmux workspace panels.
///
/// Tracks a bidirectional mapping between tmux pane IDs (e.g. `"%1"`) and
/// cmux panel UUIDs. On each `%layout-change` event it:
/// - Creates new cmux splits for tmux panes that have no corresponding panel
/// - Orphans panels whose tmux panes have disappeared from that window
/// - Adopts orphaned panels when their pane reappears in another window
///   (handles `break-pane` / `join-pane` without recreating the panel)
/// - Purges panels that were orphaned but never adopted
///
/// **Zoom handling:** tmux sends the full layout in every `%layout-change`
/// regardless of whether the window is zoomed. Reconciliation always runs.
/// The zoom flag is exposed via `TmuxLayout.isZoomed` for display use only.
///
/// **Move-pane handling:** when a pane disappears from window A's layout,
/// its panel is placed in an "orphan" set rather than closed immediately.
/// A deferred task runs after the current run-loop cycle completes. If the
/// pane reappears in window B's layout before the purge, it is adopted there.
/// If not adopted, the panel is closed.
///
/// All methods must be called on the **main thread**.
final class TmuxLayoutReconciler {

    /// Pane ID (e.g. `"%1"`) → panel UUID for currently tracked panes.
    private var trackedPanes: [String: UUID] = [:]
    /// Panel UUID → pane ID (reverse of `trackedPanes`).
    private var panelToPane: [UUID: String] = [:]
    /// Window ID → set of pane IDs currently tracked in that window.
    private var windowPanes: [String: Set<String>] = [:]
    /// Pane ID → window ID for currently tracked panes.
    private var paneToWindow: [String: String] = [:]
    /// Panes that disappeared from their last known window but have not yet been
    /// purged. Values are the panel UUIDs that will be closed on purge.
    private var orphanedPanes: [String: UUID] = [:]
    /// Pane IDs that the user explicitly closed while the pane was still alive.
    /// Suppressed from future reconciliation until the pane truly exits tmux.
    private var userDismissedPanes: Set<String> = []
    /// True when a purge task is already queued (prevents duplicate scheduling).
    private var purgePending = false

    /// The workspace this reconciler interacts with. Stored weakly so the
    /// reconciler does not create a retain cycle.
    private weak var workspace: (any TmuxReconcilerWorkspace)?

    // MARK: - Lifecycle

    /// Attach the reconciler to its workspace. Call once after initialisation
    /// and before delivering any events via `apply(_:)`.
    @MainActor
    func attach(to workspace: any TmuxReconcilerWorkspace) {
        self.workspace = workspace
    }

    // MARK: - Public API

    /// Process a tmux control event.
    @MainActor
    func apply(_ event: TmuxControlEvent) {
        guard let workspace else { return }

        switch event {
        case .layoutChange(let layout):
            reconcile(layout: layout, workspace: workspace)

        case .windowClose(let window):
            // Close all panels for panes in this window immediately.
            if let paneIds = windowPanes.removeValue(forKey: window) {
                for paneId in paneIds {
                    paneToWindow.removeValue(forKey: paneId)
                    userDismissedPanes.remove(paneId)
                    if let panelId = trackedPanes.removeValue(forKey: paneId) {
                        panelToPane.removeValue(forKey: panelId)
                        workspace.closePanel(panelId, force: true)
                    }
                }
            }

        case .exit, .windowAdd,
             .sessionRenamed, .sessionsChanged, .windowRenamed,
             .sessionWindowChanged, .windowPaneChanged,
             .paneModeChanged, .pasteBufferChanged, .clientSessionChanged:
            // These events are handled at the Workspace level.
            break
        }
    }

    /// Returns the cmux panel UUID mapped to the given tmux pane ID, or nil.
    @MainActor func panelId(forTmuxPane paneId: String) -> UUID? {
        trackedPanes[paneId]
    }

    /// Returns the tmux window ID for the panel with the given UUID, or nil.
    @MainActor func windowId(forPanel panelId: UUID) -> String? {
        guard let paneId = panelToPane[panelId] else { return nil }
        return paneToWindow[paneId]
    }

    /// Returns all currently tracked cmux panel UUIDs.
    @MainActor func allTrackedPanelIds() -> Set<UUID> {
        Set(trackedPanes.values)
    }

    /// Remove tracking for a specific cmux panel (called when the user closes it).
    /// Adds the pane to the dismissed set so subsequent `%layout-change` events
    /// do not reopen a panel for a pane the user intentionally closed.
    @MainActor func removeTracking(forPanel panelId: UUID) {
        guard let paneId = panelToPane.removeValue(forKey: panelId) else { return }
        trackedPanes.removeValue(forKey: paneId)
        if let windowId = paneToWindow.removeValue(forKey: paneId) {
            windowPanes[windowId]?.remove(paneId)
        }
        userDismissedPanes.insert(paneId)
    }

    /// Clear all tracked state (called when the session changes or disconnects).
    @MainActor func reset() {
        trackedPanes.removeAll()
        panelToPane.removeAll()
        windowPanes.removeAll()
        paneToWindow.removeAll()
        orphanedPanes.removeAll()
        userDismissedPanes.removeAll()
        purgePending = false
    }

    // MARK: - Private reconciliation

    @MainActor
    private func reconcile(layout: TmuxLayout, workspace: any TmuxReconcilerWorkspace) {
        let window = layout.windowId
        let livePaneIds = Set(layout.allPaneIds)
        let previousPanesInWindow = windowPanes[window] ?? []

        // --- Step 1: Adopt orphaned panes that reappeared in this window ---
        // This handles break-pane / join-pane: a pane that was orphaned from
        // another window is rebinding here before its deferred purge fires.
        for paneId in livePaneIds {
            if let orphanPanelId = orphanedPanes.removeValue(forKey: paneId) {
                // Rebind the existing panel to this window.
                trackedPanes[paneId] = orphanPanelId
                panelToPane[orphanPanelId] = paneId
                paneToWindow[paneId] = window
                // Remove from any stale window tracking.
                for wid in windowPanes.keys where wid != window {
                    windowPanes[wid]?.remove(paneId)
                }
            }
        }

        // --- Step 2: Orphan panes that disappeared from this window ---
        // Do not close immediately — give the next reconciliation cycle a chance
        // to adopt them if they reappear in another window (break-pane).
        let removedFromThisWindow = previousPanesInWindow.subtracting(livePaneIds)
        for paneId in removedFromThisWindow {
            paneToWindow.removeValue(forKey: paneId)
            windowPanes[window]?.remove(paneId)
            // Purge the dismissed-pane entry for this pane regardless; the pane
            // is leaving its current window context and dismissal is no longer valid.
            userDismissedPanes.remove(paneId)
            if let panelId = trackedPanes.removeValue(forKey: paneId) {
                panelToPane.removeValue(forKey: panelId)
                orphanedPanes[paneId] = panelId
            }
        }
        // Schedule a deferred purge. If the pane reappears in another window's
        // layout change (dispatched before the purge task runs), it will be
        // adopted in Step 1 and removed from orphanedPanes first.
        schedulePurgeIfNeeded(workspace: workspace)

        // --- Step 3: Create panels for panes new to this window ---
        // "New" means: live in this window AND not already tracked.
        // Dismissed panes are skipped — the user intentionally closed them.
        let newPanes = livePaneIds
            .subtracting(trackedPanes.keys)
            .subtracting(userDismissedPanes)
            .sorted { a, b in
                let na = Int(a.dropFirst()) ?? 0
                let nb = Int(b.dropFirst()) ?? 0
                return na < nb
            }

        var reconciledPaneIds: Set<String> = livePaneIds.filter { trackedPanes[$0] != nil }
        reconciledPaneIds.formUnion(userDismissedPanes.intersection(livePaneIds))

        for paneId in newPanes {
            if let panelId = workspace.newTerminalSplitForTmuxPane(paneId, windowHint: window) {
                trackedPanes[paneId] = panelId
                panelToPane[panelId] = paneId
                paneToWindow[paneId] = window
                reconciledPaneIds.insert(paneId)
            }
            // If creation fails the pane is excluded from reconciledPaneIds
            // and will be retried on the next %layout-change.
        }

        windowPanes[window] = reconciledPaneIds
    }

    /// Schedule a deferred orphan purge unless one is already queued.
    ///
    /// The purge runs after the current run-loop cycle, which is after any
    /// queued `%layout-change` events have been processed on the main thread.
    /// This gives move-pane events one reconcile cycle to adopt the orphan.
    @MainActor
    private func schedulePurgeIfNeeded(workspace: any TmuxReconcilerWorkspace) {
        guard !purgePending, !orphanedPanes.isEmpty else { return }
        purgePending = true
        // Capture the workspace reference for the async closure.
        // The workspace is a long-lived object; the weak capture is a safety net.
        Task { @MainActor [weak self, weak workspace] in
            guard let self, let workspace else { return }
            self.purgePending = false
            self.purgeOrphans(workspace: workspace)
        }
    }

    /// Close all panels that are still in the orphan set (were never adopted).
    @MainActor
    private func purgeOrphans(workspace: any TmuxReconcilerWorkspace) {
        for (_, panelId) in orphanedPanes {
            workspace.closePanel(panelId, force: true)
        }
        orphanedPanes.removeAll()
    }
}
