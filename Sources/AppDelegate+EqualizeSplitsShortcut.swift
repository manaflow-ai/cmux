import AppKit
import CmuxPanes
import CmuxSettings

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
        if workspace.layoutMode == .canvas {
            let executor = CanvasActionExecutor(workspace: workspace)
            let didEqualizeWidths = executor.perform(.alignment(.equalizeWidths))
            let didEqualizeHeights = executor.perform(.alignment(.equalizeHeights))
#if DEBUG
            if !didEqualizeWidths && !didEqualizeHeights {
                cmuxDebugLog("shortcut.action name=equalizeSplits result=noCanvasChange workspaceId=\(workspace.id)")
            }
#endif
            return
        }
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

    /// Runs one pane-resize step against the focused split tree. Menu actions,
    /// command-palette commands, and key events all call this method so the
    /// focused Dock and main workspace share the same mutation path.
    @discardableResult
    func performResizePaneShortcut(
        direction: ResizeDirection,
        preferredWindow: NSWindow? = nil
    ) -> Bool {
        let targetWindow = preferredWindow ?? shortcutRoutingActiveWindow
        let action: KeyboardShortcutSettings.Action = {
            switch direction {
            case .left: .resizePaneLeft
            case .right: .resizePaneRight
            case .up: .resizePaneUp
            case .down: .resizePaneDown
            }
        }()

        if let dock = focusedDockStoreForShortcut(
            action: action,
            preferredWindow: targetWindow
        ) {
            dock.noteKeyboardFocusIntent(window: targetWindow)
            let didResize = dock.performShortcutCommand(.resizePane(direction))
            if !didResize { NSSound.beep() }
#if DEBUG
            cmuxDebugLog(
                "shortcut.action name=resizePane direction=\(direction) amount=\(PaneResizeStepSettings(defaults: .standard).currentPixels()) "
                    + "result=\(didResize ? 1 : 0) scope=dock"
            )
#endif
            return true
        }

        let manager = activeTabManagerForCommands(preferredWindow: targetWindow)
        let didResize = manager?.resizeFocusedPane(
            direction: direction,
            amount: PaneResizeStepSettings(defaults: .standard).currentPixels()
        ) ?? false
#if DEBUG
        cmuxDebugLog(
            "shortcut.action name=resizePane direction=\(direction) amount=\(PaneResizeStepSettings(defaults: .standard).currentPixels()) "
                + "result=\(didResize ? 1 : 0) scope=workspace"
        )
#endif
        return didResize
    }
    func handlePaneSizingShortcut(event: NSEvent, equalize: Bool) -> Bool {
        if equalize {
            if performFocusedDockShortcut(
                .equalizeSplits,
                action: .equalizeSplits,
                event: event
            ) {
                return true
            }
            performEqualizeSplitsShortcut()
            return true
        }

        let paneResizeActions: [(KeyboardShortcutSettings.Action, ResizeDirection)] = [
            (.resizePaneLeft, .left),
            (.resizePaneRight, .right),
            (.resizePaneUp, .up),
            (.resizePaneDown, .down),
        ]
        for (action, direction) in paneResizeActions {
            guard matchConfiguredShortcut(event: event, action: action) else { continue }
            _ = performResizePaneShortcut(
                direction: direction,
                preferredWindow: event.window ?? shortcutRoutingActiveWindow
            )
            return true
        }

        return false
    }
}
