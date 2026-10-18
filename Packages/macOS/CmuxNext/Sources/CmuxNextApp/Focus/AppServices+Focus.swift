import CmuxNextBrowser
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextFocus

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
                chromiumWarmup.tabSignal(.paletteOpen)
                windows.active?.focus.send(.overlayOpened(.palette))
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

    /// The chrome of page `key` gives the keyboard back to the page: its
    /// window's coordinator targets the page content (WebKit or Chromium).
    /// A split's terminal tab, minted by a window, got its daemon surface. A focus wait by that
    /// surface made before the store had it (the crate's copy of the tab may not name the surface
    /// yet: the confirm sends no topology) takes the tab's stable id, with the same target,
    /// pane and intent generation, so it lands now.
    func terminalConfirmed(_ tab: TabModel) {
        guard let surface = tab.daemonSurface else { return }
        for controller in windows.controllers {
            guard let wait = controller.focus.state.expectation, wait.key == .surface(surface) else { continue }
            controller.focus.expect(.tab(tab.id), target: wait.target, awayFrom: wait.awayFrom, generation: wait.generation)
        }
    }

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
