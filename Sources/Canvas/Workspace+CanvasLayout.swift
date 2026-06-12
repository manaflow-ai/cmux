import Foundation
import AppKit
import Bonsplit
import CmuxCanvas
import CmuxCanvasUI

/// Canvas-layout behavior for `Workspace`. The workspace stays the owner of
/// panels, focus, and bonsplit bookkeeping; canvas mode only changes how the
/// same panel set is presented.
extension Workspace {
    /// Switches the workspace between split and canvas layout.
    ///
    /// Entering canvas mode seeds pane frames from the current bonsplit
    /// geometry so the canvas initially looks identical to the splits. The
    /// split tree itself is left untouched, so switching back restores it.
    func setLayoutMode(_ mode: WorkspaceLayoutMode) {
        guard mode != layoutMode else { return }
        if mode == .canvas {
            canvasModel.seedFromSplitFrames(splitPaneFramesByPanelId())
        }
        layoutMode = mode
    }

    /// Toggles between split and canvas layout.
    func toggleCanvasLayout() {
        setLayoutMode(layoutMode == .canvas ? .splits : .canvas)
    }

    /// Canvas-mode directional focus: nearest pane spatially, then reveal it.
    func moveCanvasFocus(direction: NavigationDirection) {
        guard let from = focusedPanelId ?? orderedPanelIds.first else { return }
        guard let target = canvasModel.pane(direction.canvasDirection, from: from) else { return }
        focusPanel(target)
        canvasModel.viewport?.revealPane(target, animated: true)
    }

    /// The bonsplit pane currently containing the panel's tab, used by
    /// canvas panes that host split-mode SwiftUI panel views.
    func bonsplitPaneId(forPanelId panelId: UUID) -> PaneID? {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return nil }
        for paneId in bonsplitController.allPaneIds {
            if bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == tabId }) {
                return paneId
            }
        }
        return nil
    }

    /// Called by the canvas after a user gesture commits a frame change.
    func noteCanvasLayoutChanged() {
        // Session persistence snapshots read `canvasModel` directly; nothing
        // else needs to react to pure geometry changes today.
    }

    // MARK: - Session persistence

    /// Canvas pane frames in z-order for the session snapshot; `nil` when the
    /// workspace has never entered canvas mode.
    func canvasSessionPaneSnapshots() -> [SessionCanvasPaneSnapshot]? {
        let snapshots: [SessionCanvasPaneSnapshot] = canvasModel.layout.paneIDs.compactMap { paneID in
            guard let frame = canvasModel.frame(of: paneID.rawValue) else { return nil }
            return SessionCanvasPaneSnapshot(
                panelId: paneID.rawValue,
                x: frame.origin.x,
                y: frame.origin.y,
                width: frame.width,
                height: frame.height
            )
        }
        return snapshots.isEmpty ? nil : snapshots
    }

    /// Restores canvas frames (remapped onto the freshly minted panel ids)
    /// and the layout mode. Setting `layoutMode` directly skips the
    /// seed-from-splits path, which would overwrite the restored frames.
    func restoreCanvasState(
        from snapshot: SessionWorkspaceSnapshot,
        oldToNewPanelIds: [UUID: UUID]
    ) {
        if let canvasPanes = snapshot.canvasPanes {
            let frames: [(id: UUID, frame: CGRect)] = canvasPanes.compactMap { pane in
                guard let newId = oldToNewPanelIds[pane.panelId], panels[newId] != nil else {
                    return nil
                }
                return (newId, CGRect(x: pane.x, y: pane.y, width: pane.width, height: pane.height))
            }
            canvasModel.restoreFrames(frames)
        }
        if snapshot.layoutMode == WorkspaceLayoutMode.canvas.rawValue {
            layoutMode = .canvas
        }
    }

    /// Current split-layout frames per panel, used to seed canvas frames so
    /// entering canvas mode preserves what the user sees. Only the selected
    /// tab of each split pane has on-screen geometry; the rest are placed by
    /// the canvas placer afterwards.
    private func splitPaneFramesByPanelId() -> [UUID: CGRect] {
        let snapshot = bonsplitController.layoutSnapshot()
        var frames: [UUID: CGRect] = [:]
        for pane in snapshot.panes {
            guard let selectedTabId = pane.selectedTabId,
                  let tabUUID = UUID(uuidString: selectedTabId),
                  let panelId = panelIdFromSurfaceId(TabID(uuid: tabUUID)) else {
                continue
            }
            frames[panelId] = CGRect(
                x: pane.frame.x - snapshot.containerFrame.x,
                y: pane.frame.y - snapshot.containerFrame.y,
                width: pane.frame.width,
                height: pane.frame.height
            )
        }
        return frames
    }
}

extension NavigationDirection {
    /// Maps bonsplit's split-navigation direction onto the canvas model's.
    var canvasDirection: CanvasDirection {
        switch self {
        case .left: return .left
        case .right: return .right
        case .up: return .up
        case .down: return .down
        }
    }
}
