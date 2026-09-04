import CmuxTerminalCore
import GhosttyKit

extension GhosttyNSView {
    func activateContainerFocusFromPointerDown() {
        guard let terminalSurface else { return }

        switch terminalSurface.focusPlacement {
        case .workspace:
            AppDelegate.shared?.noteTerminalKeyboardFocusIntent(
                workspaceId: terminalSurface.tabId,
                panelId: terminalSurface.id,
                in: window
            )
        case .rightSidebarDock:
            DockSplitStore.focusPanelFromDockPointer(terminalSurface.id, window: window)
        }
    }

    func terminalPointerShouldForwardActivation() -> Bool {
        guard let terminalSurface else { return false }

        let mouseCaptured = terminalSurface.surface.map {
            ghostty_surface_mouse_captured($0)
        } ?? false
        let wasFocusedBeforePointerDown: Bool

        if desiredFocus {
            switch terminalSurface.focusPlacement {
            case .workspace:
                wasFocusedBeforePointerDown = terminalSurface.owningWorkspace()?
                    .isFocusedTerminalInputSurface(terminalSurface.id) == true
            case .rightSidebarDock:
                wasFocusedBeforePointerDown = TerminalPointerFocusActivationPolicy()
                    .shouldForwardToTerminal(
                        currentPanelId: terminalSurface.id,
                        focusedPanelId: DockSplitStore.liveStore(
                            containingPanel: terminalSurface.id
                        )?.focusedPanelId
                    )
            }
        } else {
            wasFocusedBeforePointerDown = false
        }

        return TerminalPointerFocusActivationPolicy().shouldForwardToTerminal(
            mouseCaptured: mouseCaptured,
            wasFocusedBeforePointerDown: wasFocusedBeforePointerDown
        )
    }
}
