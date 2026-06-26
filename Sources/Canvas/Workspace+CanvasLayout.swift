import Foundation
import AppKit
import Bonsplit
import CmuxCanvas
import CmuxCanvasUI

extension Notification.Name {
    /// Posted (object = the `Workspace`) whenever its `layoutMode` changes,
    /// so window chrome can reflect canvas vs splits without observing the
    /// workspace directly.
    static let workspaceLayoutModeDidChange = Notification.Name("cmux.workspaceLayoutModeDidChange")
}

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
        let wasCanvasHosted = layoutMode.usesCanvasHost
        if mode.usesCanvasHost && !wasCanvasHosted {
            canvasModel.seedFromSplitFrames(splitPaneFramesByPanelId())
        }
        layoutMode = mode
        // The rendered-panel set changes shape with the mode (canvas hosts each
        // pane's selected terminal directly in the pane hierarchy; splits host
        // every selected tab through the window portal), so re-derive portal
        // visibility immediately instead of waiting for the next layout event.
        //
        // Entering canvas: clear the terminal portal layer now. Otherwise the
        // split-mode terminal surfaces keep floating at their old split frames
        // (over the canvas) during the async SwiftUI mount, and stay there
        // until some later layout event happens to reconcile them — the ghost
        // terminal artifacts Aziz reported on toggle. The canvas mount re-shows
        // each visible pane's selected terminal via its portal-detach path.
        // Leaving canvas: reconcile to the split-mode rendered set so the
        // re-attached terminals show at the correct split frames.
        if mode.usesCanvasHost && !wasCanvasHosted {
            hideAllTerminalPortalViews()
        } else if !mode.usesCanvasHost && wasCanvasHosted {
            reconcileTerminalPortalVisibilityForCurrentRenderedLayout()
        }
        reconcileBrowserPortalVisibilityForCurrentRenderedLayout(
            reason: "workspace.setLayoutMode.\(mode.rawValue)"
        )
        // Let chrome (the toolbar mode toggle) reflect the change regardless
        // of which entrypoint drove it (shortcut, palette, menu, toolbar).
        NotificationCenter.default.post(name: .workspaceLayoutModeDidChange, object: self)
    }

    /// Cycles between split, canvas, and horizontal pages layout.
    func toggleCanvasLayout() {
        setLayoutMode(layoutMode.nextCycledMode)
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

    /// Canvas panes (frames, tabs, selection) in z-order for the session
    /// snapshot; `nil` when the workspace has never entered canvas mode.
    func canvasSessionPaneSnapshots() -> [SessionCanvasPaneSnapshot]? {
        let snapshots: [SessionCanvasPaneSnapshot] = canvasModel.persistablePanes.map { pane in
            SessionCanvasPaneSnapshot(
                panelId: pane.paneId,
                x: pane.frame.origin.x,
                y: pane.frame.origin.y,
                width: pane.frame.width,
                height: pane.frame.height,
                panelIds: pane.panelIds,
                selectedPanelId: pane.selectedPanelId
            )
        }
        return snapshots.isEmpty ? nil : snapshots
    }

    /// Restores canvas panes (remapped onto the freshly minted panel ids)
    /// and the layout mode. Setting `layoutMode` directly skips the
    /// seed-from-splits path, which would overwrite the restored frames.
    func restoreCanvasState(
        from snapshot: SessionWorkspaceSnapshot,
        oldToNewPanelIds: [UUID: UUID]
    ) {
        if let canvasPanes = snapshot.canvasPanes {
            let restored: [CanvasModel.PersistablePane] = canvasPanes.compactMap { pane in
                // Pre-tab snapshots stored a single panel in `panelId`.
                let oldPanelIds = pane.panelIds ?? [pane.panelId]
                let newPanelIds = oldPanelIds.compactMap { oldId -> UUID? in
                    guard let newId = oldToNewPanelIds[oldId], panels[newId] != nil else { return nil }
                    return newId
                }
                guard !newPanelIds.isEmpty else { return nil }
                let oldSelected = pane.selectedPanelId ?? pane.panelId
                let newSelected = oldToNewPanelIds[oldSelected].flatMap { newPanelIds.contains($0) ? $0 : nil }
                return CanvasModel.PersistablePane(
                    // Pane identity follows its first surviving panel so it
                    // stays stable across the id remap.
                    paneId: newPanelIds[0],
                    frame: CGRect(x: pane.x, y: pane.y, width: pane.width, height: pane.height),
                    panelIds: newPanelIds,
                    selectedPanelId: newSelected ?? newPanelIds[0]
                )
            }
            canvasModel.restorePanes(restored)
        }
        if let rawLayoutMode = snapshot.layoutMode,
           let restoredLayoutMode = WorkspaceLayoutMode(rawValue: rawLayoutMode),
           restoredLayoutMode.usesCanvasHost {
            layoutMode = restoredLayoutMode
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

extension Workspace {
    /// Cycles the focused canvas pane's tabs by `offset` (wrapping). Returns
    /// `false` when the focused pane has fewer than two tabs, so the caller
    /// can fall back to bonsplit cycling semantics.
    func selectAdjacentCanvasTab(offset: Int) -> Bool {
        guard let focusedPanelId,
              let paneID = canvasModel.paneID(containing: focusedPanelId),
              let tabs = canvasModel.layout.panelIds(in: paneID),
              tabs.count > 1,
              let selected = canvasModel.layout.selectedPanelId(in: paneID),
              let index = tabs.firstIndex(of: selected) else {
            return false
        }
        let next = tabs[(index + offset + tabs.count) % tabs.count]
        focusPanel(next.rawValue)
        canvasModel.viewport?.modelDidChangeExternally(animated: false)
        return true
    }
}

/// The kind of surface `openNewCanvasPane` should create.
enum CanvasNewPaneType {
    case terminal
    case browser
}

extension Workspace {
    /// Creates a new surface as its own free-floating canvas pane (not joined
    /// as a tab of an existing pane), the automation counterpart to the
    /// canvas "new pane" gesture. Returns the new surface/panel UUID, or `nil`
    /// when creation fails (e.g. no focused bonsplit pane, or the browser is
    /// disabled). Must be called in canvas mode.
    @discardableResult
    func openNewCanvasPane(type: CanvasNewPaneType, focus: Bool = true) -> UUID? {
        guard layoutMode.usesCanvasHost else { return nil }
        guard let focusedPaneId = bonsplitController.focusedPaneId else { return nil }
        let newPanelId: UUID
        switch type {
        case .terminal:
            guard let panel = newTerminalSurface(inPane: focusedPaneId, focus: focus) else {
                return nil
            }
            newPanelId = panel.id
        case .browser:
            guard let panel = newBrowserSurface(inPane: focusedPaneId, focus: focus) else {
                return nil
            }
            newPanelId = panel.id
        }
        // Give the new surface its own canvas pane (the placer positions it
        // near the focused pane) rather than joining it as a tab.
        canvasModel.syncPanes(panelIds: orderedPanelIds, focusedPanelId: newPanelId)
        focusPanel(newPanelId)
        canvasModel.viewport?.modelDidChangeExternally(animated: false)
        canvasModel.viewport?.revealPane(newPanelId, animated: true)
        return newPanelId
    }

    /// Makes a freshly created panel a tab of the canvas pane hosting
    /// `anchor` (the Cmd+T-in-canvas semantics). Ensures the panel exists in
    /// the canvas model first, since panel creation can run before the next
    /// descriptor sync.
    func joinNewPanelIntoCanvasPane(_ panelId: UUID, anchor: UUID) {
        guard layoutMode.usesCanvasHost else { return }
        canvasModel.syncPanes(
            panelIds: orderedPanelIds,
            focusedPanelId: anchor
        )
        canvasModel.joinPanel(panelId, withPaneContaining: anchor)
        focusPanel(panelId)
        canvasModel.viewport?.modelDidChangeExternally(animated: false)
    }
}


extension Workspace {
    /// Mirrors canvas pane z-order onto portal-hosted browser webviews so a
    /// front pane's webview stacks above a back pane's.
    @discardableResult
    func syncCanvasBrowserPortalZOrder() -> Bool {
        guard layoutMode == .canvas else { return false }
        let zOrder = canvasModel.layout.paneIDs
        var didUpdate = false
        for panel in panels.values {
            guard let browserPanel = panel as? BrowserPanel,
                  !browserPanel.canvasInlineHostingActive,
                  let paneID = canvasModel.paneID(containing: browserPanel.id),
                  let z = zOrder.firstIndex(of: paneID) else { continue }
            BrowserWindowPortalRegistry.updateEntryVisibility(
                for: browserPanel.webView,
                visibleInUI: true,
                zPriority: 2 + z
            )
            didUpdate = true
        }
        return didUpdate
    }
}
