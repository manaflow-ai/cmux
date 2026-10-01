import CmuxNextDaemon

/// What Cmd-T opens in a pane.
nonisolated enum NewTabKind: Equatable, Sendable {
    case terminal
    /// A browser tab on `engine` (nil: `browser.defaultEngine`).
    case browser(engine: String?)

    /// The pane's selected tab decides: a browser tab (daemon or
    /// session-local) gets a browser tab on its engine, so cookies and
    /// extensions stay in that engine; a terminal, a remote terminal or an
    /// empty pane gets a terminal tab.
    static func resolve(selectedKind: TabKind?, engine: String?, isLocalBrowser: Bool) -> NewTabKind {
        if selectedKind == .browser { return .browser(engine: engine) }
        if isLocalBrowser { return .browser(engine: nil) }
        return .terminal
    }
}
