import AppKit
import CmuxPanes

extension AppDelegate {
    /// Fixed incremental movement used by the directional pane resize actions.
    private static let paneResizeStep: CGFloat = 20

    private static let paneShareShortcuts: [(
        action: KeyboardShortcutSettings.Action,
        axis: PaneAxis,
        share: CGFloat
    )] = [
        (.setPaneWidth25Percent, .width, 0.25),
        (.setPaneWidth50Percent, .width, 0.5),
        (.setPaneWidth75Percent, .width, 0.75),
        (.setPaneHeight25Percent, .height, 0.25),
        (.setPaneHeight50Percent, .height, 0.5),
        (.setPaneHeight75Percent, .height, 0.75),
    ]

    /// Routes configured exact pane-share shortcuts.
    func handlePaneShareShortcut(event: NSEvent) -> Bool {
        let actions = Self.paneShareShortcuts.map { $0.action }
        guard let action = preferredMatchingShortcutAction(event: event, actions: actions),
              !explicitShortcutOverrideShouldPreemptImplicitDefault(
                event: event,
                matchedAction: action,
                actionFamily: actions
              ),
              let route = Self.paneShareShortcuts.first(where: { $0.action == action }) else {
            return false
        }

        performPaneShareShortcut(axis: route.axis, share: route.share, event: event)
        return true
    }

    /// Applies an exact focused-branch share in the main-window context for `event`.
    func performPaneShareShortcut(axis: PaneAxis, share: CGFloat, event: NSEvent) {
        if focusedDockStoreForShortcut(preferredWindow: event.window) != nil {
            NSSound.beep()
            return
        }

        let manager = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager
        if shouldSuppressSplitShortcutForTransientTerminalFocusState(tabManager: manager) {
            return
        }
        let result = manager?.setSelectedPaneShare(axis: axis, share: share)
            ?? .rejected(reason: "No workspace is selected.")
        if !result.didApply { NSSound.beep() }
#if DEBUG
        cmuxDebugLog(
            "shortcut.action name=setPaneShare axis=\(axis) share=\(share) " +
            "result=\(String(describing: result))"
        )
#endif
    }

    /// Routes configured directional pane-resize shortcuts.
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

    /// Applies a directional resize in the main-window context for `event`.
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
