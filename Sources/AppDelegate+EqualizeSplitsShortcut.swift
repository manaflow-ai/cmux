import AppKit
import CmuxPanes

extension AppDelegate {
    private static let paneResizeStep: CGFloat = 20

    func handlePaneResizeShortcut(event: NSEvent) -> Bool {
        let routes: [(KeyboardShortcutSettings.Action, ResizeDirection, String, UInt16)] = [
            (.growPaneLeft, .left, "←", 123),
            (.growPaneRight, .right, "→", 124),
            (.growPaneUp, .up, "↑", 126),
            (.growPaneDown, .down, "↓", 125),
        ]

        guard let route = routes.first(where: { action, _, glyph, keyCode in
            matchConfiguredDirectionalShortcut(
                event: event,
                action: action,
                arrowGlyph: glyph,
                arrowKeyCode: keyCode
            )
        }) else {
            return false
        }

        performPaneResizeShortcut(direction: route.1, event: event)
        return true
    }

    func performPaneResizeShortcut(direction: ResizeDirection, event: NSEvent) {
        if focusedDockStoreForShortcut(preferredWindow: event.window) != nil {
            NSSound.beep()
#if DEBUG
            cmuxDebugLog("shortcut.action name=growPane direction=\(direction) result=unsupportedDock")
#endif
            return
        }

        let manager = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager
        if shouldSuppressSplitShortcutForTransientTerminalFocusState(tabManager: manager) {
            return
        }
        let result = manager?.resizeSelectedPane(
            direction: direction,
            amountInPixels: Self.paneResizeStep
        ) ?? .rejected(reason: "No workspace is selected.")

        if !result.didApply { NSSound.beep() }
#if DEBUG
        cmuxDebugLog("shortcut.action name=growPane direction=\(direction) result=\(String(describing: result))")
#endif
    }

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
}
