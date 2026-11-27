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
            // The portal callback normally converges Bonsplit's selected pane
            // with the AppKit first responder. A manual-mirror (Cloud) portal
            // can remain interactive for one reconciliation turn while its
            // callback is being rebound, though. Move the workspace model at
            // pointer-down time as well so input and the visible focus ring
            // cannot temporarily disagree.
            // `panels` is the same membership guard the portal callback uses.
            // A remote-tmux mirror pane surface is not a workspace panel, so
            // without it every pointer-down in one of those would ask the
            // container to select a pane it does not own.
            terminalSurface.owningWorkspace()?.focusPanelFromTerminalInput(terminalSurface.id)
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
