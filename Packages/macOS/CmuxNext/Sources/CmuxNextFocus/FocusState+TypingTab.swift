extension FocusState {
    /// The focused terminal or browser page that keys typed now are for (pane, tab, whether a page); nil for other focus.
    /// A window's key hold waits while its content is not shown yet (REOPEN-F4).
    public var awaitableContent: (pane: String, tab: String, isPage: Bool)? {
        switch resolved {
        case .terminal(let pane, let tab): (pane, tab, false)
        case .browserPage(let pane, let tab): (pane, tab, true)
        default: nil
        }
    }

    /// The focus is on its way to a tab other than the focused one (a creation's new tab the window does not show
    /// yet): the person left the focused content. `cmux-focus-core`'s `awaits_other_tab`, whose change re-applies the
    /// responder (P0 INVERSE-KEY).
    public var awaitsOtherTab: Bool {
        switch expectation?.key {
        case .tab(let tab)?: resolved.tab != tab
        case .surface?: true
        case nil: false
        }
    }

    /// The focused terminal's tab; nil when the focus is not on a terminal.
    public var terminalTab: String? {
        if case .terminal(_, let tab) = resolved { return tab } else { return nil }
    }
}
