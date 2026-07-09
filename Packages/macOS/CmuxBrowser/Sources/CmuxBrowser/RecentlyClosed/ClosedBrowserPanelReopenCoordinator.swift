public import Foundation
import Dispatch

/// Owns the "reopen the most recently closed browser panel" orchestration the
/// app-target `TabManager` used to inline for the Cmd+Shift+T legacy-stack path:
/// draining the per-window recently-closed stack, resolving the snapshot's
/// origin workspace, selecting it when needed, restoring the panel into its old
/// placement, and the two-runloop-turn focus re-assertion that pins the reopened
/// browser panel against stale focus callbacks.
///
/// The bodies are byte-faithful lifts of the former
/// `TabManager.reopenMostRecentlyClosedBrowserPanelFromLegacyStack()`,
/// `clearRecentlyClosedBrowserPanelHistory()`,
/// `mostRecentLegacyClosedBrowserPanelClosedAt()`,
/// `enforceReopenedBrowserFocus(tabId:reopenedPanelId:preReopenFocusedPanelId:)`,
/// and `enforceReopenedBrowserFocusIfNeeded(…)`. The recently-closed stack is
/// the package ``BrowserManaging`` model injected at construction; the workspace
/// resolution and the app-coupled effects (the `BrowserAvailabilitySettings`
/// gate, the `selectWorkspaceId(_:notificationDismissalContext:)` selection flow
/// with its `AppDelegate.shared` notification-store dismissal, the
/// `PanelIdResolver`-backed pre-reopen focused-panel read, and the
/// `rememberFocusedSurface` write) stay app-side behind ``ClosedBrowserPanelReopenHosting``.
/// The bonsplit-coupled placement walk stays app-side behind
/// ``ClosedBrowserPanelReopenWorkspaceHandle``.
///
/// `@MainActor` because every entry point is one main-actor turn driven by the
/// reopen shortcut, menu, or command palette, and both the host and the resolved
/// workspace handle live there — co-locating removes any bridging, the same
/// isolation ruling as the sibling ``BrowserOpenCoordinator``.
@MainActor
public final class ClosedBrowserPanelReopenCoordinator {
    private weak var host: (any ClosedBrowserPanelReopenHosting)?
    private let browserModel: any BrowserManaging<ClosedBrowserPanelRestoreSnapshot>

    /// Creates the coordinator over the window's recently-closed browser-panel
    /// model. Call ``attach(host:)`` to wire the window-side host before driving
    /// any reopen path.
    public init(browserModel: any BrowserManaging<ClosedBrowserPanelRestoreSnapshot>) {
        self.browserModel = browserModel
    }

    /// Attaches the window-side host that resolves workspaces and performs the
    /// app-coupled selection/focus-memory/availability effects.
    public func attach(host: any ClosedBrowserPanelReopenHosting) {
        self.host = host
    }

    // MARK: - Reopen

    /// Reopens the most recently closed browser panel from the per-window legacy
    /// stack, restoring it into the workspace that originally owned it. Returns
    /// `false` when browsing is disabled or no restorable snapshot remains.
    @discardableResult
    public func reopenMostRecentlyClosedBrowserPanelFromLegacyStack() -> Bool {
        guard let host, host.isBrowserEnabled else { return false }

        while let snapshot = browserModel.popMostRecentlyClosedBrowserPanel() {
            // The legacy stack must restore into the workspace that originally owned the
            // browser. If that workspace is gone, the snapshot is stale and we drop it
            // instead of barging into whatever workspace happens to be selected now
            // (which surfaced yesterday's browser inside today's unrelated workspaces).
            guard let targetWorkspace = host.reopenBrowserWorkspaceHandle(forWorkspaceId: snapshot.workspaceId) else {
                continue
            }
            let preReopenFocusedPanelId = host.focusedPanelId(forWorkspaceId: snapshot.workspaceId)

            if host.selectedWorkspaceId != snapshot.workspaceId {
                host.selectWorkspaceForBrowserReopen(snapshot.workspaceId)
            }

            if let reopenedPanelId = targetWorkspace.reopenClosedBrowserPanel(snapshot) {
                enforceReopenedBrowserFocus(
                    tabId: snapshot.workspaceId,
                    reopenedPanelId: reopenedPanelId,
                    preReopenFocusedPanelId: preReopenFocusedPanelId
                )
                return true
            }
        }

        return false
    }

    /// Clears the entire per-window recently-closed browser-panel history.
    public func clearRecentlyClosedBrowserPanelHistory() {
        browserModel.clearRecentlyClosedBrowserPanels()
    }

    /// When the most recently closed browser panel was closed, if any (the
    /// recency the History menu sorts windows by).
    public func mostRecentLegacyClosedBrowserPanelClosedAt() -> Date? {
        browserModel.mostRecentClosedBrowserPanelClosedAt
    }

    // MARK: - Focus enforcement

    private func enforceReopenedBrowserFocus(
        tabId: UUID,
        reopenedPanelId: UUID,
        preReopenFocusedPanelId: UUID?
    ) {
        // Keep workspace-switch restoration pinned to the reopened browser panel.
        host?.rememberFocusedSurface(workspaceId: tabId, surfaceId: reopenedPanelId)
        enforceReopenedBrowserFocusIfNeeded(
            tabId: tabId,
            reopenedPanelId: reopenedPanelId,
            preReopenFocusedPanelId: preReopenFocusedPanelId
        )

        // Some stale focus callbacks can land one runloop turn later. Re-assert focus in two
        // consecutive turns, but only when focus drifted back to the pre-reopen panel.
        //
        // Byte-faithful lift: the legacy body used two nested `DispatchQueue.main.async`
        // hops to land on the next two runloop turns, and the observable two-turn
        // re-assertion timing must be preserved exactly, so the hops are kept verbatim
        // rather than modernized to a Clock task (a behavior-adjacent change).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.enforceReopenedBrowserFocusIfNeeded(
                tabId: tabId,
                reopenedPanelId: reopenedPanelId,
                preReopenFocusedPanelId: preReopenFocusedPanelId
            )
            DispatchQueue.main.async { [weak self] in
                self?.enforceReopenedBrowserFocusIfNeeded(
                    tabId: tabId,
                    reopenedPanelId: reopenedPanelId,
                    preReopenFocusedPanelId: preReopenFocusedPanelId
                )
            }
        }
    }

    private func enforceReopenedBrowserFocusIfNeeded(
        tabId: UUID,
        reopenedPanelId: UUID,
        preReopenFocusedPanelId: UUID?
    ) {
        guard let host,
              host.selectedWorkspaceId == tabId,
              let tab = host.reopenBrowserWorkspaceHandle(forWorkspaceId: tabId),
              tab.hasPanel(reopenedPanelId) else {
            return
        }

        host.rememberFocusedSurface(workspaceId: tabId, surfaceId: reopenedPanelId)

        guard tab.focusedPanelId != reopenedPanelId else { return }

        if let focusedPanelId = tab.focusedPanelId,
           let preReopenFocusedPanelId,
           focusedPanelId != preReopenFocusedPanelId {
            return
        }

        tab.focusPanel(reopenedPanelId)
    }
}
