extension AppDelegate {
    func performEqualizeSplitsShortcut() {
        guard let tabManager, let workspace = tabManager.selectedWorkspace else {
#if DEBUG
            cmuxDebugLog("shortcut.action name=equalizeSplits result=noWorkspace")
#endif
            return
        }
#if DEBUG
        cmuxDebugLog("shortcut.action name=equalizeSplits workspaceId=\(workspace.id)")
#endif
        if shouldSuppressSplitShortcutForTransientTerminalFocusState(tabManager: tabManager) {
            return
        }
        let didEqualize = tabManager.equalizeSplits(tabId: workspace.id)
#if DEBUG
        if !didEqualize {
            cmuxDebugLog("shortcut.action name=equalizeSplits result=noSplitOrFailed workspaceId=\(workspace.id)")
        }
#endif
    }

    @discardableResult
    func performGrowPaneShortcut(direction: ResizeDirection) -> Bool {
        guard let tabManager, let workspace = tabManager.selectedWorkspace else {
#if DEBUG
            cmuxDebugLog("shortcut.action name=growPane direction=\(direction.debugName) result=noWorkspace")
#endif
            return false
        }
#if DEBUG
        cmuxDebugLog("shortcut.action name=growPane direction=\(direction.debugName) workspaceId=\(workspace.id)")
#endif
        if shouldSuppressSplitShortcutForTransientTerminalFocusState(
            direction: direction.splitDirection,
            tabManager: tabManager
        ) {
            return false
        }
        let didResize = tabManager.resizeFocusedSplit(direction: direction)
#if DEBUG
        if !didResize {
            cmuxDebugLog("shortcut.action name=growPane direction=\(direction.debugName) result=noSplitOrFailed workspaceId=\(workspace.id)")
        }
#endif
        return didResize
    }
}

extension ResizeDirection {
    var splitDirection: SplitDirection {
        switch self {
        case .left: return .left
        case .right: return .right
        case .up: return .up
        case .down: return .down
        }
    }

    var debugName: String {
        switch self {
        case .left: return "left"
        case .right: return "right"
        case .up: return "up"
        case .down: return "down"
        }
    }
}
