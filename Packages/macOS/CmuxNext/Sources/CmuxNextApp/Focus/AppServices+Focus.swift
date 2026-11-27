import CmuxNextBrowser
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextFocus

// App-wide inputs to the per-window focus coordinators.
extension AppServices {
    /// The palette is a panel above the window it opens over: an overlay of
    /// that window's focus while it is open. Reported synchronously by the
    /// palette, before the key-window change it causes, so a click that
    /// closes it is judged with the overlay already gone (input-spec.md B7).
    ///
    /// The overlay goes on the window the panel is a child of, not on
    /// `windows.active`: the two disagree whenever the palette opens over a
    /// window that is not the active one (an explicit `relativeTo:`, or a
    /// press in one window while another holds the keys, where `active` is
    /// the event's window and the palette parents to the key window). The
    /// overlay then landed on a window the palette was not over, leaving the
    /// window under the panel with an empty stack: it goes on applying focus
    /// to its terminal while the palette holds the keyboard (input-spec.md
    /// W5, W6, and F1's "an overlay is the keyboard target").
    func observePaletteForFocus() {
        palette.onVisibilityChange = { [weak self] open, host in
            guard let self else { return }
            if open {
                let over = host.flatMap { windows.owner(of: $0) } ?? windows.active
                over?.focus.send(.overlayOpened(.palette))
            } else {
                for controller in windows.controllers where controller.focus.state.overlays.contains(.palette) {
                    controller.focus.send(.overlayClosed(.palette))
                }
            }
        }
    }

    /// Keyboard focus left page `key` (Tab past its last element, Shift-Tab
    /// past its first): its omnibar takes it.
    /// Only while the page has the keyboard: a late report never moves
    /// focus the user put elsewhere.
    func focusAddressBarAfterPage(_ key: String) {
        for controller in windows.controllers {
            guard case .browserPage(_, let tab) = controller.focus.state.resolved, tab == key else { continue }
            controller.focus.send(.focusTarget(.addressBar, source: .keyboard))
            return
        }
    }

    /// A split's terminal got its daemon surface on `daemon` (no topology send): its theme follows the
    /// confirmed terminal; a surface wait in a window of `daemon` (surfaces are per daemon) takes the tab id.
    func terminalConfirmed(_ tab: TabModel, on daemon: DaemonService) {
        if let entry = cache.existingTerminal(tab.id) { themes.catchUp(entry, fresh: true) } // its theme key moved
        for controller in windows.controllers where controller.content?.daemon === daemon { controller.content?.rekeySurfaceWait() }
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

    /// Page `key`'s DevTools opened docked (it takes the keyboard) or
    /// closed (the keyboard returns to the page).
    func devToolsDidChange(_ key: String, state: BrowserDevToolsState, focused: Bool) {
        for controller in windows.controllers {
            guard let pane = controller.content?.panes.values.first(where: { $0.currentTabKey == key }) else { continue }
            if state.isOpen, state.dock.isDocked, focused {
                if controller.focus.state.pane != pane.paneKey { controller.focus.send(.focusPane(pane.paneKey, source: .intent)) }
                controller.focus.send(.focusTarget(.devTools, source: .intent))
            } else if !state.isOpen, controller.focus.state.resolved == .devTools(pane: pane.paneKey, tab: key) {
                controller.focus.send(.focusTarget(.content, source: .intent))
            }
            return
        }
    }

    /// The window whose content shows `pane`.
    func windowController(showing pane: PaneController) -> WindowController? {
        windows.controllers.first { $0.content === pane.workspace }
    }
}
