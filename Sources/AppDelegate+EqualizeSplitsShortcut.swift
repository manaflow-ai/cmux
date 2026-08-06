import AppKit
import CmuxPanes

extension AppDelegate {
    /// Fixed incremental movement used by the directional pane resize actions.
    private static let paneResizeStep: CGFloat = 20
    /// Recoverable maximum used by the existing width-only shortcut.
    private static let maximizedPaneShare: CGFloat = 0.9
    private static let paneShareShortcutActions: [KeyboardShortcutSettings.Action] = [
        .setPaneWidthRatioByNumber,
        .setPaneHeightRatioByNumber,
        .maximizePaneWidth,
    ]

    private static let paneHeightMaximizeShortcutActions: [KeyboardShortcutSettings.Action] = [
        .maximizePaneHeight,
    ]

    /// Routes configured exact pane-share shortcuts.
    func handlePaneShareShortcut(event: NSEvent) -> Bool {
        let actions = Self.paneShareShortcutActions + Self.paneHeightMaximizeShortcutActions
        guard let action = preferredMatchingShortcutAction(event: event, actions: actions),
              !explicitShortcutOverrideShouldPreemptImplicitDefault(
                event: event,
                matchedAction: action,
                actionFamily: actions
              ) else {
            return false
        }

        if action == .maximizePaneHeight {
            performPaneHeightMaximizeShortcut(event: event)
            return true
        }

        guard let route = paneShareShortcutRoute(event: event, action: action) else {
            return false
        }

        performPaneShareShortcut(axis: route.axis, share: route.share, event: event)
        return true
    }

    /// Resolves a ratio-family shortcut to one exact-share request.
    private func paneShareShortcutRoute(
        event: NSEvent,
        action: KeyboardShortcutSettings.Action
    ) -> (axis: PaneAxis, share: CGFloat)? {
        switch action {
        case .setPaneWidthRatioByNumber, .setPaneHeightRatioByNumber:
            guard let digit = routableNumberedConfiguredShortcutDigit(
                event: event,
                action: action
            ), let share = Self.panePresetShare(for: digit) else {
                return nil
            }
            let axis: PaneAxis = action == .setPaneWidthRatioByNumber ? .width : .height
            return (axis, share)
        case .maximizePaneWidth:
            return (.width, Self.maximizedPaneShare)
        default:
            return nil
        }
    }

    /// Resolves the compact preset family to the focused pane's exact share.
    private static func panePresetShare(for digit: Int) -> CGFloat? {
        switch digit {
        case 1: return 1.0 / 3.0
        case 2: return 1.0 / 2.0
        case 3: return 2.0 / 3.0
        default: return nil
        }
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

    /// Toggles height-only maximize through the same selected-pane action
    /// path used by the other sizing shortcuts.
    func performPaneHeightMaximizeShortcut(event: NSEvent) {
        if focusedDockStoreForShortcut(preferredWindow: event.window) != nil {
            NSSound.beep()
            return
        }
        let manager = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager
        if shouldSuppressSplitShortcutForTransientTerminalFocusState(tabManager: manager) {
            return
        }
        let result = manager?.toggleSelectedPaneHeightMaximize()
            ?? .rejected(reason: "No workspace is selected.")
        if !result.didApply { NSSound.beep() }
#if DEBUG
        cmuxDebugLog("shortcut.action name=togglePaneHeightMaximize result=\(String(describing: result))")
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

    func performEqualizeSplitsShortcut(event: NSEvent) {
        let manager = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager
        guard let manager, let workspace = manager.selectedWorkspace else {
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
        if shouldSuppressSplitShortcutForTransientTerminalFocusState(tabManager: manager) {
            return
        }
        let didEqualize = manager.equalizeSplits(tabId: workspace.id)
#if DEBUG
        if !didEqualize {
            cmuxDebugLog("shortcut.action name=equalizeSplits result=noSplitOrFailed workspaceId=\(workspace.id)")
        }
#endif
    }
}
