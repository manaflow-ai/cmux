import AppKit
import CmuxNextBrowser
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextEnergy
import CmuxNextFeatures
import CmuxNextFocus
import CmuxNextPalette

// App-wide inputs to the per-window focus coordinators.
extension AppServices {
    /// Whether the key router decided a key-down: the main menu bar does not search for it (`ActionMenuBar`).
    var decidedKey: @MainActor (NSEvent) -> Bool {
        { [weak self] in self?.keyRouter.decided.contains($0) ?? false }
    }

    /// The palette's hooks once it is built (`PaletteOnDemand`): hidden rows, open timings, the shortcut
    /// editor, and the focus overlay. The palette is a panel above the active window: an overlay of that
    /// window's focus while it is open. Reported synchronously by the
    /// palette, before the key-window change it causes, so a click that
    /// closes it is judged with the overlay already gone (input-spec.md B7).
    func paletteBuilt(_ palette: PaletteController) {
        // Energy Saver's session rows show only while they can act (neither while its feature is off);
        // Memory Saver's mode rows only with its feature on (fixed for the launch).
        let memorySaverRows: Set<ActionID> = features.isEnabled(.memorySaverSetting)
            ? [] : Set(MemorySaverMode.allCases.map(\.actionID))
        // View Metrics shows only while the metricsView feature is on (a socket run still says why it is off).
        let featureOffIDs: Set<ActionID> = features.isEnabled(.metricsView) ? [] : ["diagnostics.viewMetrics"]
        palette.hiddenActionIDs = { [energy] in
            energy.driver.paletteHiddenActionIDs.union(memorySaverRows)
                .union(AgentPaneTunables.pointerInspector.value ? [] : ["agentPane.togglePointerInspector"])
                .union(featureOffIDs)
        }
        palette.onPresented = { DebugTimings.palettePresented($0) }
        // The key-down that opens the palette (a synthesized one under `debug.key`), for its input stage.
        palette.openingEventTimestamp = { [inputDispatch] in
            let event = inputDispatch.event
            return event?.type == .keyDown ? event?.timestamp : nil
        }
        palette.shortcutRecorder.editor = paletteShortcutEditor
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
