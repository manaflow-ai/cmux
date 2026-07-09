public import Foundation
public import Bonsplit

/// Owns the surface-move decision the legacy `AppDelegate` kept inline: the
/// destination-pane resolution, the same-workspace-split / same-workspace-move /
/// cross-workspace path selection, the bonsplit-tab → panel-id indirection, and
/// the existing-workspace move-target enumeration. Conforms to
/// ``PaneLayoutControlling`` so app surfaces (terminal NSView submenu, bonsplit
/// context menu, drop targets, control socket) drive one owner.
///
/// Lifted one-for-one from `AppDelegate.moveSurface`, `AppDelegate.moveBonsplitTab`,
/// and the move-target loop of `AppDelegate.workspaceMoveTargets`. The coordinator
/// holds no app object: every live read/mutation routes through
/// ``PaneSurfaceMoveHosting``, and the cross-workspace detach-scoped tail (whose
/// detached-surface transfer token is an app type) is performed wholesale by the
/// host from the value-typed ``PaneSurfaceMoveCrossWorkspacePlan`` the coordinator
/// computes.
///
/// `@MainActor` because surface movement is a main-actor UI flow and the host +
/// live workspace state both live there; co-locating removes any bridging
/// (mirrors the sibling ``WorkspaceContextMenuCoordinator``/
/// ``WorkspaceDropCoordinator`` isolation ruling).
@MainActor
public final class PaneSurfaceMoveCoordinator: PaneLayoutControlling {
    private weak var host: (any PaneSurfaceMoveHosting)?

    /// Creates the coordinator. The host is attached separately at the
    /// composition root so the app-target conformer can reference the coordinator
    /// during its own construction.
    public init() {}

    /// Attaches the app-side host that performs the irreducible live mutations.
    public func attach(host: any PaneSurfaceMoveHosting) {
        self.host = host
    }

    // MARK: - move(surface:)

    @discardableResult
    public func move(surface request: PaneSurfaceMoveRequest) -> Bool {
        guard let host else { return false }

        // Legacy: locateSurface(panelId) → source window+workspace.
        guard let source = host.resolveSourceLocation(surfaceId: request.panelId) else {
            return false
        }
        // Legacy: destination manager + workspace must exist.
        guard host.workspaceExists(request.targetWorkspaceId) else { return false }

        // Legacy destination-pane resolution: requested pane (if present in the
        // destination) → destination focused pane → destination first pane.
        guard let resolvedTargetPane = host.resolveTargetPane(
            inWorkspace: request.targetWorkspaceId,
            requested: request.targetPane
        ) else {
            return false
        }

        if request.targetWorkspaceId == source.workspaceId {
            // Same-workspace path.
            if let split = request.splitTarget {
                return host.splitSameWorkspace(
                    workspaceId: source.workspaceId,
                    panelId: request.panelId,
                    targetPane: resolvedTargetPane,
                    orientation: split.orientation,
                    insertFirst: split.insertFirst,
                    focus: request.focus
                )
            }
            return host.moveSameWorkspace(
                workspaceId: source.workspaceId,
                panelId: request.panelId,
                targetPane: resolvedTargetPane,
                atIndex: request.targetIndex,
                focus: request.focus
            )
        }

        // Cross-workspace path. The destination window id is only resolved when
        // the move should focus the destination window (legacy `focusWindow ?
        // windowId(for: destinationManager) : nil`).
        let destinationWindowId = request.focusWindow
            ? host.windowId(forWorkspace: request.targetWorkspaceId)
            : nil
        let plan = PaneSurfaceMoveCrossWorkspacePlan(
            destinationWorkspaceId: request.targetWorkspaceId,
            destinationWindowId: destinationWindowId,
            targetPane: resolvedTargetPane,
            targetIndex: request.targetIndex,
            splitTarget: request.splitTarget,
            focus: request.focus
        )
        return host.performCrossWorkspaceMove(
            panelId: request.panelId,
            sourceWorkspaceId: source.workspaceId,
            sourceWindowId: source.windowId,
            plan: plan
        )
    }

    // MARK: - moveBonsplitTab(tabId:)

    @discardableResult
    public func moveBonsplitTab(
        tabId: UUID,
        toWorkspace targetWorkspaceId: UUID,
        targetPane: PaneID?,
        targetIndex: Int?,
        splitTarget: PaneSurfaceMoveRequest.SplitTarget?,
        focus: Bool,
        focusWindow: Bool
    ) -> Bool {
        guard let host, let located = host.resolveBonsplitLocation(tabId: tabId) else {
            return false
        }
        return move(surface: PaneSurfaceMoveRequest(
            panelId: located.panelId,
            targetWorkspaceId: targetWorkspaceId,
            targetPane: targetPane,
            targetIndex: targetIndex,
            splitTarget: splitTarget,
            focus: focus,
            focusWindow: focusWindow
        ))
    }

    // MARK: - moveTargets(for:)

    public func moveTargets(
        for summaries: [PaneSurfaceMoveWindowSummary],
        excludingWorkspaceId: UUID?
    ) -> [WorkspaceMoveTarget] {
        var targets: [WorkspaceMoveTarget] = []
        targets.reserveCapacity(summaries.reduce(0) { $0 + $1.workspaces.count })
        for summary in summaries {
            for workspace in summary.workspaces {
                if workspace.workspaceId == excludingWorkspaceId { continue }
                targets.append(
                    WorkspaceMoveTarget(
                        windowId: summary.windowId,
                        workspaceId: workspace.workspaceId,
                        windowLabel: summary.windowLabel,
                        workspaceTitle: workspace.title,
                        isCurrentWindow: summary.isCurrentWindow
                    )
                )
            }
        }
        return targets
    }
}
