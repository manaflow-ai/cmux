import CmuxNextActions

// App-wide inputs to the per-window focus coordinators.
extension AppServices {
    /// The palette is a panel above the active window: an overlay of that
    /// window's focus while it is open. Reported synchronously by the
    /// palette, before the key-window change it causes, so a click that
    /// closes it is judged with the overlay already gone (input-spec.md B7).
    func observePaletteForFocus() {
        palette.onVisibilityChange = { [weak self] open in
            guard let self else { return }
            if open {
                windows.active?.focus.send(.overlayOpened(.palette))
            } else {
                for controller in windows.controllers where controller.focus.state.overlays.contains(.palette) {
                    controller.focus.send(.overlayClosed(.palette))
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
