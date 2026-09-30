import CmuxNextActions
import Observation

// App-wide inputs to the per-window focus coordinators.
extension AppServices {
    /// The palette is a panel above the active window: an overlay of that
    /// window's focus while it is open (`paletteOpen` in the registry).
    func observePaletteForFocus() {
        let registry = registry
        paletteObservation = Task { [weak self] in
            var wasOpen = false
            for await open in Observations({ registry.context.contains(.paletteOpen) }) {
                guard let self, open != wasOpen else { continue }
                wasOpen = open
                if open {
                    windows.active?.focus.send(.overlayOpened(.palette))
                } else {
                    for controller in windows.controllers where controller.focus.state.overlays.contains(.palette) {
                        controller.focus.send(.overlayClosed(.palette))
                    }
                }
            }
        }
    }

    /// The window whose content shows `pane`.
    func windowController(showing pane: PaneController) -> WindowController? {
        windows.controllers.first { $0.content === pane.workspace }
    }
}
