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

    /// The chrome of page `key` gives the keyboard back to the page: its
    /// window's coordinator targets the page content (WebKit or Chromium).
    func returnFocusToPage(_ key: String) {
        for controller in windows.controllers {
            guard let pane = controller.content?.panes.values.first(where: { $0.currentTabKey == key }) else { continue }
            controller.focus.send(.focusPane(pane.paneKey, source: .intent))
            return
        }
    }

    /// The window whose content shows `pane`.
    func windowController(showing pane: PaneController) -> WindowController? {
        windows.controllers.first { $0.content === pane.workspace }
    }
}
