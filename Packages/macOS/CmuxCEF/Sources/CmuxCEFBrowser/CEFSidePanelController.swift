import AppKit
public import CmuxBrowser
public import CmuxCEF

/// cmux's side panel header over Chromium's (fork API 13) for one Chromium
/// page: shown while the page window's side panel is open, as a subview of
/// the page's host view with a hole in the page window
/// (`CEFHostView.sidePanelHeaderRect`) so it shows and takes the mouse over
/// the page. Owns the header view, the last state read from Chromium and the
/// refresh batching; the page owns this controller.
///
/// Reference: cmux Next `CmuxNextBrowser/CEF/CEFSidePanelController.swift`.
@MainActor
public final class CEFSidePanelController {
    private weak var browser: CEFBrowser?
    private let shim: @MainActor () -> CEFShimLibrary?
    /// The header, while the panel is open.
    public private(set) var header: ChromiumSidePanelHeaderView?
    /// The panel state of the last read, while the panel is open.
    public private(set) var state: CEFSidePanelState?
    private var refreshPending = false

    init(browser: CEFBrowser, shim: @escaping @MainActor () -> CEFShimLibrary?) {
        self.browser = browser
        self.shim = shim
    }

    /// CMUX_SIDE_PANEL_CHANGED: read the state on the next turn (the event
    /// arrives inside Chromium's layout, many times per open or close
    /// animation), once for all events of this turn.
    func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        Task { @MainActor [weak self] in
            self?.refreshPending = false
            self?.refresh()
        }
    }

    /// Reads the panel state again and shows, moves or removes the header.
    public func refresh() {
        guard let browser else { return }
        guard let id = browser.browserID, let shim = shim(), shim.forkAPIVersion() >= CEFSidePanelState.minimumForkAPI,
              let state = shim.takeString(shim.sidePanelState(id)).flatMap(CEFSidePanelState.init(json:)) else {
            removeHeader(from: browser.hostView)
            return
        }
        apply(state, in: browser.hostView)
    }

    /// Shows `state`'s header over `hostView` (tests drive this directly).
    func apply(_ state: CEFSidePanelState, in hostView: CEFHostView) {
        let header = header ?? makeHeader(in: hostView)
        self.state = state
        header.apply(Self.content(for: state))
        let frame = state.headerFrame(inPage: hostView.bounds)
        header.frame = frame
        // Chromium keeps the panel at the window's edge as the page resizes;
        // the header follows that edge and the top until the next report.
        header.autoresizingMask = state.header.midX >= hostView.bounds.width / 2
            ? [.minXMargin, .minYMargin] : [.maxXMargin, .minYMargin]
        hostView.sidePanelHeaderRect = frame
    }

    nonisolated static func content(for state: CEFSidePanelState) -> ChromiumSidePanelHeaderContent {
        ChromiumSidePanelHeaderContent(
            title: state.title,
            icon: state.icon,
            isPinned: state.isPinned,
            controls: state.visibleControls.compactMap { ChromiumSidePanelControl(rawValue: $0.rawValue) }
        )
    }

    /// Runs a header control through Chromium's own button. Returns false
    /// when Chromium does not show it.
    @discardableResult
    public func press(_ control: ChromiumSidePanelControl) -> Bool {
        guard let id = browser?.browserID, let shim = shim() else { return false }
        let pressed = shim.sidePanelPress(id, control.rawValue) == 1
        // Chromium updates its header (pin state) in the same turn; the panel
        // closing reports CMUX_SIDE_PANEL_CHANGED.
        scheduleRefresh()
        return pressed
    }

    private func makeHeader(in hostView: CEFHostView) -> ChromiumSidePanelHeaderView {
        let header = ChromiumSidePanelHeaderView()
        header.onPress = { [weak self] control in self?.press(control) }
        hostView.addSubview(header)
        self.header = header
        return header
    }

    func removeHeader(from hostView: CEFHostView) {
        state = nil
        hostView.sidePanelHeaderRect = nil
        guard let header else { return }
        self.header = nil
        header.removeFromSuperview()
    }
}
