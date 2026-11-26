import Bonsplit
import Foundation

extension AppDelegate {
    func moveBonsplitTab(
        tabId: UUID,
        toWorkspace targetWorkspaceId: UUID,
        targetPane: PaneID? = nil,
        targetIndex: Int? = nil,
        splitTarget: (orientation: SplitOrientation, insertFirst: Bool)? = nil,
        focus: Bool = true,
        focusWindow: Bool = true
    ) -> Bool {
#if DEBUG
        let moveStart = ProcessInfo.processInfo.systemUptime
        func elapsedMs(since start: TimeInterval) -> String {
            let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
            return String(format: "%.2f", ms)
        }
        cmuxDebugLog(
            "surface.moveBonsplit.begin tab=\(tabId.uuidString.prefix(5)) targetWs=\(targetWorkspaceId.uuidString.prefix(5)) " +
            "targetPane=\(targetPane?.id.uuidString.prefix(5) ?? "auto") targetIndex=\(targetIndex.map(String.init) ?? "nil")"
        )
#endif
        guard let located = locateBonsplitSurface(tabId: tabId) else {
            // The tab isn't in any workspace pane tree — it may be a Dock tab
            // being dragged out into the main split area. Route the live panel
            // out of its Dock and into the destination workspace.
            if let dockSource = locateDockSurface(tabId: tabId) {
                return moveDockSurfaceToWorkspace(
                    sourceDock: dockSource.dock,
                    panelId: dockSource.panelId,
                    toWorkspace: targetWorkspaceId,
                    targetPane: targetPane,
                    targetIndex: targetIndex,
                    splitTarget: splitTarget,
                    focus: focus,
                    focusWindow: focusWindow
                )
            }
#if DEBUG
            cmuxDebugLog(
                "surface.moveBonsplit.fail tab=\(tabId.uuidString.prefix(5)) reason=tabNotFound " +
                "targetWs=\(targetWorkspaceId.uuidString.prefix(5)) elapsedMs=\(elapsedMs(since: moveStart))"
            )
#endif
            return false
        }
#if DEBUG
        cmuxDebugLog(
            "surface.moveBonsplit.located tab=\(tabId.uuidString.prefix(5)) panel=\(located.panelId.uuidString.prefix(5)) " +
            "sourceWs=\(located.workspaceId.uuidString.prefix(5)) sourceWin=\(located.windowId.uuidString.prefix(5))"
        )
#endif
        let moved = moveSurface(
            panelId: located.panelId,
            toWorkspace: targetWorkspaceId,
            targetPane: targetPane,
            targetIndex: targetIndex,
            splitTarget: splitTarget,
            focus: focus,
            focusWindow: focusWindow
        )
#if DEBUG
        cmuxDebugLog(
            "surface.moveBonsplit.end tab=\(tabId.uuidString.prefix(5)) panel=\(located.panelId.uuidString.prefix(5)) " +
            "moved=\(moved ? 1 : 0) elapsedMs=\(elapsedMs(since: moveStart))"
        )
#endif
        return moved
    }

}
