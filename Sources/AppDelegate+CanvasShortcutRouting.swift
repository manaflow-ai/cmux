import CmuxCanvas
import CmuxPanes
import CmuxSettings

extension AppDelegate {
    func performToggleSplitZoomShortcut(tabManager routedManager: TabManager?) {
        if let workspace = routedManager?.selectedWorkspace, workspace.layoutMode == .canvas {
            _ = CanvasActionExecutor(workspace: workspace).perform(.toggleOverview)
        } else {
            _ = routedManager?.toggleFocusedSplitZoom()
#if DEBUG
            recordGotoSplitZoomIfNeeded(tabManager: routedManager)
#endif
        }
    }
}

extension SplitDirection {
    var canvasDirection: CanvasDirection {
        switch self {
        case .left: return .left
        case .right: return .right
        case .up: return .up
        case .down: return .down
        }
    }
}
