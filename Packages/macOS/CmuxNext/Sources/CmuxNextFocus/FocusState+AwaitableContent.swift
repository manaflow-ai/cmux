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
}
