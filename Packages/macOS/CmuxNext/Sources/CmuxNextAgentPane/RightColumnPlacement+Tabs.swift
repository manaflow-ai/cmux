public import CmuxNextAgentPanePlacement
public import CmuxNextDaemon

// The tab kinds of RightColumnPlacement (CmuxNextAgentPanePlacement), read from the daemon's tabs.
public extension RightColumnPlacement.Kind {
    /// The kind of an existing tab that opens beside a chat: a browser, a local terminal, or a
    /// document (`document`: the tab shows the Changes diff page); nil for anything else, a remote
    /// terminal included.
    init?(opening tab: TabKind, document: Bool) {
        switch tab {
        case .browser: self = .browser
        case .pty: self = .terminal
        default:
            guard document else { return nil }
            self = .document
        }
    }
}

public extension RightColumnPlacement.Kind {
    /// Whether `tab` makes its pane hold this kind for the same-kind rule: a local or remote terminal,
    /// a browser tab, or (`document`: the tab shows the Changes diff page) a diff.
    func isHeld(by tab: TabModel, document: Bool) -> Bool {
        switch (self, tab.kind) {
        case (.terminal, .pty), (.terminal, .remoteTerminal), (.browser, .browser): true
        case (.document, _): document
        default: false
        }
    }
}

public extension TabModel {
    /// Whether this tab is a page (GitHub, a file, a diff, What's New) or a browser tab, not a
    /// terminal or a chat: a page beside another pane opens what it links in its own pane
    /// (``LinkOpenPlacement``), while a terminal or a chat keeps its split, so the place someone
    /// types never goes behind a tab.
    /// Internal pages are conversation tabs with a page source (`page-tabs-v1`), so a conversation
    /// tab counts only by its ``page`` (review of #37573 at bf2ce583).
    var showsPage: Bool {
        switch kind {
        case .browser, .other: true
        case .conversation: page != nil && agentSession == nil
        case .pty, .remoteTerminal: false
        }
    }
}
