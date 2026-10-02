public import AppKit

/// cmux's side panel header over Chromium's (fork API 13): shown while the
/// window's side panel is open and this tab is shown, with an occlusion hole
/// so the mouse reaches it over the page window.
extension CEFTab {
    /// CMUX_SIDE_PANEL_CHANGED: read the state on the next turn (the event
    /// arrives inside Chromium's layout, about 190 times per open or close
    /// animation), once for all events of this turn.
    func scheduleSidePanelRefresh() {
        guard !sidePanelRefreshPending else { return }
        sidePanelRefreshPending = true
        Task { @MainActor [weak self] in
            self?.sidePanelRefreshPending = false
            self?.sidePanelChanged()
        }
    }

    /// A header control ran, or a refresh is due: read the state again.
    func sidePanelChanged() {
        guard let browserID, let shim = runtime.shim, runtime.forkAPIVersion >= 13,
              let state = shim.takeString(shim.sidePanelState(browserID)).flatMap(CEFSidePanelState.init(json:)) else {
            removeSidePanelHeader()
            return
        }
        let header = sidePanelHeader ?? makeSidePanelHeader()
        sidePanelState = state
        header.apply(state)
        container.layoutContent()
    }

    /// The header's frame in the content view, or nil without a side panel.
    var sidePanelHeaderFrame: CGRect? {
        guard let state = sidePanelState, sidePanelHeader != nil else { return nil }
        return state.headerFrame(inPage: devToolsController.frames(in: container.bounds).page)
    }

    func pressSidePanel(_ control: CEFSidePanelState.Control) {
        guard let browserID, let shim = runtime.shim else { return }
        _ = shim.sidePanelPress(browserID, control.rawValue)
        // Chromium updates its header (pin state) in the same turn; the panel
        // closing reports CMUX_SIDE_PANEL_CHANGED.
        scheduleSidePanelRefresh()
    }

    private func makeSidePanelHeader() -> SidePanelHeaderView {
        let header = SidePanelHeaderView()
        header.onPress = { [weak self] control in self?.pressSidePanel(control) }
        container.addSubview(header)
        sidePanelHeader = header
        return header
    }

    private func removeSidePanelHeader() {
        sidePanelState = nil
        guard let header = sidePanelHeader else { return }
        sidePanelHeader = nil
        header.removeFromSuperview()
        container.layoutContent()
    }
}

extension CEFTab {
    /// cmux's side panel header while shown (`debug.cef`): its title, the
    /// controls it shows and its screen frame (AppKit origin).
    public var sidePanelDiagnostic: (title: String, controls: [String], pinned: Bool, chromiumFocusable: Int?, frame: CGRect)? {
        guard let state = sidePanelState, let header = sidePanelHeader, let window = header.window else { return nil }
        let controls: [(Bool, CEFSidePanelState.Control)] = [(state.showsPin, .pin), (state.showsOpenInNewTab, .openInNewTab),
                                                              (state.showsMoreInfo, .moreInfo), (true, .close)]
        return (state.title, controls.filter(\.0).map(\.1.rawValue), state.isPinned, state.chromiumFocusableControls,
                window.convertToScreen(header.convert(header.bounds, to: nil)))
    }

    /// Runs one header control as a click would (`debug.cef` `side_panel`).
    public func pressSidePanelForDebug(_ control: String) -> Bool {
        if control == "refresh" {
            sidePanelChanged()
            return sidePanelState != nil
        }
        guard sidePanelState != nil, let control = CEFSidePanelState.Control(rawValue: control) else { return false }
        pressSidePanel(control)
        return true
    }
}
