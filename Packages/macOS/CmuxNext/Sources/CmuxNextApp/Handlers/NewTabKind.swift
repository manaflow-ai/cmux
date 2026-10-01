import CmuxNextDaemon

/// What Cmd-T opens in a pane.
nonisolated enum NewTabKind: Equatable, Sendable {
    case terminal
    /// A browser tab on `engine` (nil: `browser.defaultEngine`).
    case browser(engine: String?)

    /// The selected tab of the pane decides. Today Cmd-T always opens a
    /// terminal tab.
    static func resolve(selectedKind: TabKind?, engine: String?, isLocalBrowser: Bool) -> NewTabKind {
        .terminal
    }
}
