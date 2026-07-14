import AppKit
import CmuxCanvas
import CmuxPanes
import CmuxSettings

extension AppDelegate {
    @discardableResult
    func performBrowserSplitShortcut(direction: SplitDirection) -> Bool {
        guard BrowserAvailabilitySettings.isEnabled() else {
#if DEBUG
            cmuxDebugLog("split.browser.shortcut blocked reason=browser_disabled")
#endif
            return false
        }

        _ = synchronizeActiveMainWindowContext(preferredWindow: shortcutRoutingActiveWindow)

        if let workspace = tabManager?.selectedWorkspace, workspace.layoutMode == .canvas {
            guard let panelId = workspace.openNewCanvasPane(
                type: .browser,
                focus: true,
                direction: direction.canvasDirection
            ) else {
                return false
            }
            _ = focusBrowserAddressBar(panelId: panelId)
            return true
        }

#if DEBUG
        let directionLabel: String
        switch direction {
        case .left: directionLabel = "left"
        case .right: directionLabel = "right"
        case .up: directionLabel = "up"
        case .down: directionLabel = "down"
        }
        let selectedTabBefore = tabManager?.selectedTabId?.uuidString.prefix(5) ?? "nil"
        let focusedPanelBefore = tabManager?.selectedWorkspace?.focusedPanelId?.uuidString.prefix(5) ?? "nil"
        cmuxDebugLog(
            "split.browser.shortcut pre dir=\(directionLabel) " +
            "tab=\(selectedTabBefore) focusedPanel=\(focusedPanelBefore)"
        )
#endif

        guard let panelId = tabManager?.createBrowserSplit(direction: direction) else {
#if DEBUG
            cmuxDebugLog("split.browser.shortcut failed dir=\(directionLabel)")
#endif
            return false
        }

#if DEBUG
        let selectedTabAfter = tabManager?.selectedTabId?.uuidString.prefix(5) ?? "nil"
        let focusedPanelAfter = tabManager?.selectedWorkspace?.focusedPanelId?.uuidString.prefix(5) ?? "nil"
        cmuxDebugLog(
            "split.browser.shortcut post dir=\(directionLabel) " +
            "created=\(panelId.uuidString.prefix(5)) tab=\(selectedTabAfter) focusedPanel=\(focusedPanelAfter)"
        )
#endif

        _ = focusBrowserAddressBar(panelId: panelId)
        return true
    }

    func performToggleSplitZoomShortcut(tabManager routedManager: TabManager?) {
        if let workspace = routedManager?.selectedWorkspace, workspace.layoutMode == .canvas {
            _ = CanvasActionExecutor(workspace: workspace).perform(.toggleOverview)
        } else {
            _ = routedManager?.toggleFocusedSplitZoom()
        }
    }

    /// Returns nil when the event is not a reorder shortcut, false when a
    /// reorder shortcut came from a non-main window, and true once consumed.
    func performReorderShortcut(event: NSEvent) -> Bool? {
        let move: (workspace: Bool, offset: Int)
        if matchConfiguredShortcut(event: event, action: .moveSurfaceLeft) {
            move = (false, -1)
        } else if matchConfiguredShortcut(event: event, action: .moveSurfaceRight) {
            move = (false, 1)
        } else if matchConfiguredShortcut(event: event, action: .moveWorkspaceUp) {
            move = (true, -1)
        } else if matchConfiguredShortcut(event: event, action: .moveWorkspaceDown) {
            move = (true, 1)
        } else {
            return nil
        }

        guard let manager = preferredMainWindowContextForShortcutRouting(
            event: event,
            allowAuxiliaryFallback: false
        )?.tabManager else { return false }
        _ = move.workspace
            ? manager.moveSelectedWorkspace(by: move.offset)
            : manager.moveSelectedSurface(by: move.offset)
        return true
    }

    func performBrowserOrTextPreviewZoomShortcut(event: NSEvent, action: KeyboardShortcutSettings.Action) -> Bool {
        let focusContext = shortcutEventFocusContext(event)
        if focusContext.filePreviewTextEditorFocused {
            let targetTabs = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager
            switch action {
            case .browserZoomIn:
                return targetTabs?.zoomInFocusedTextFilePreview() ?? false
            case .browserZoomOut:
                return targetTabs?.zoomOutFocusedTextFilePreview() ?? false
            case .browserZoomReset:
                return targetTabs?.resetZoomFocusedTextFilePreview() ?? false
            default:
                return false
            }
        }

        switch action {
        case .browserZoomIn:
            return focusContext.browserPanel?.zoomIn() ?? false
        case .browserZoomOut:
            return focusContext.browserPanel?.zoomOut() ?? false
        case .browserZoomReset:
            return focusContext.browserPanel?.resetZoom() ?? false
        default:
            return false
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
