import AppKit
import CmuxPanes

extension AppDelegate {
    /// Fixed step used by the focused-pane size adjustment actions.
    private static let paneResizeStep: UInt16 = 20
    private static let paneResizeShortcutActions: [KeyboardShortcutSettings.Action] = [
        .shrinkPaneWidth,
        .growPaneWidth,
        .shrinkPaneHeight,
        .growPaneHeight,
    ]

    /// Routes configured focused-pane size adjustment shortcuts.
    func handlePaneResizeShortcut(event: NSEvent) -> Bool {
        let actions = Self.paneResizeShortcutActions
        guard let action = preferredMatchingShortcutAction(event: event, actions: actions),
              !explicitShortcutOverrideShouldPreemptImplicitDefault(
                event: event,
                matchedAction: action,
                actionFamily: actions
              ) else {
            return false
        }

        let request: (axis: PaneAxis, adjustment: PaneSizeAdjustment)
        switch action {
        case .shrinkPaneWidth:
            request = (.width, .shrink)
        case .growPaneWidth:
            request = (.width, .grow)
        case .shrinkPaneHeight:
            request = (.height, .shrink)
        case .growPaneHeight:
            request = (.height, .grow)
        default:
            return false
        }

        if performFocusedDockShortcut(
            .adjustPaneSize(
                axis: request.axis,
                adjustment: request.adjustment,
                amountPixels: Self.paneResizeStep
            ),
            action: action,
            event: event
        ) {
            return true
        }

        let manager = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager
        if shouldSuppressSplitShortcutForTransientTerminalFocusState(tabManager: manager) {
            return true
        }
        if manager?.adjustSelectedPaneSize(
            axis: request.axis,
            adjustment: request.adjustment,
            amountPixels: Self.paneResizeStep
        ) != true {
            NSSound.beep()
        }
#if DEBUG
        cmuxDebugLog(
            "shortcut.action name=\(action.rawValue) axis=\(request.axis) adjustment=\(request.adjustment)"
        )
#endif
        return true
    }
}
