public import AppKit

/// cmux's side panel header over Chromium's (fork API 13) for one tab: shown
/// while the window's side panel is open and the tab is shown, with an
/// occlusion hole so the mouse reaches it over the page window. Owns the
/// header view, the last state read from Chromium and the refresh batching;
/// the tab owns this controller (`CEFTab.sidePanel`).
@MainActor
final class CEFSidePanelController {
    private weak var tab: CEFTab?
    /// The header, while the panel is open.
    private(set) var header: SidePanelHeaderView?
    /// The panel state of the last read, while the panel is open.
    private(set) var state: CEFSidePanelState?
    private var refreshPending = false

    init(tab: CEFTab) { self.tab = tab }

    /// CMUX_SIDE_PANEL_CHANGED: read the state on the next turn (the event
    /// arrives inside Chromium's layout, about 190 times per open or close
    /// animation), once for all events of this turn.
    func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        Task { @MainActor [weak self] in
            self?.refreshPending = false
            self?.refresh()
        }
    }

    /// A header control ran, or a refresh is due: read the state again.
    func refresh() {
        guard let tab else { return }
        guard let browserID = tab.browserID, let shim = tab.runtime.shim, tab.runtime.forkAPIVersion >= 13,
              let state = shim.takeString(shim.sidePanelState(browserID)).flatMap(CEFSidePanelState.init(json:)) else {
            removeHeader(from: tab)
            return
        }
        let header = header ?? makeHeader(in: tab)
        self.state = state
        header.apply(state)
        tab.container.layoutContent()
    }

    /// The header's frame in the tab's content view, or nil without a side panel.
    var headerFrame: CGRect? {
        guard let tab, let state, header != nil else { return nil }
        return state.headerFrame(inPage: tab.devToolsController.frames(in: tab.container.bounds).page)
    }

    func press(_ control: CEFSidePanelState.Control) {
        guard let tab, let browserID = tab.browserID, let shim = tab.runtime.shim else { return }
        _ = shim.sidePanelPress(browserID, control.rawValue)
        // Chromium updates its header (pin state) in the same turn; the panel
        // closing reports CMUX_SIDE_PANEL_CHANGED.
        scheduleRefresh()
    }

    /// The header while shown (`debug.cef`): its title, the controls it
    /// shows and its screen frame (AppKit origin).
    var diagnostic: (title: String, controls: [String], pinned: Bool, chromiumFocusable: Int?, frame: CGRect)? {
        guard let state, let header, let window = header.window else { return nil }
        let controls: [(Bool, CEFSidePanelState.Control)] = [(state.showsPin, .pin), (state.showsOpenInNewTab, .openInNewTab),
                                                              (state.showsMoreInfo, .moreInfo), (true, .close)]
        return (state.title, controls.filter(\.0).map(\.1.rawValue), state.isPinned, state.chromiumFocusableControls,
                window.convertToScreen(header.convert(header.bounds, to: nil)))
    }

    /// Runs one header control as a click would (`debug.cef` `side_panel`).
    func pressForDebug(_ control: String) -> Bool {
        if control == "refresh" {
            refresh()
            return state != nil
        }
        guard state != nil, let control = CEFSidePanelState.Control(rawValue: control) else { return false }
        press(control)
        return true
    }

    private func makeHeader(in tab: CEFTab) -> SidePanelHeaderView {
        let header = SidePanelHeaderView()
        header.onPress = { [weak self] control in self?.press(control) }
        tab.container.addSubview(header)
        self.header = header
        return header
    }

    private func removeHeader(from tab: CEFTab) {
        state = nil
        guard let header else { return }
        self.header = nil
        header.removeFromSuperview()
        tab.container.layoutContent()
    }
}

/// The side panel's `debug.cef` entry points on the public tab.
extension CEFTab {
    public var sidePanelDiagnostic: (title: String, controls: [String], pinned: Bool, chromiumFocusable: Int?, frame: CGRect)? {
        sidePanel.diagnostic
    }

    public func pressSidePanelForDebug(_ control: String) -> Bool { sidePanel.pressForDebug(control) }
}
