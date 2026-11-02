extension FocusState {
    /// The tab a key typed now is for: the tab the focus is on its way to (a creation's new tab, shown and focused in
    /// the key's frame), else the focused terminal's tab. A creation hold binds each held key to it (P0 1193).
    public var typingTab: String? {
        if case .tab(let tab)? = expectation?.key { return tab }
        return terminalTab
    }

    /// The focused terminal's tab; nil when the focus is not on a terminal.
    public var terminalTab: String? {
        if case .terminal(_, let tab) = resolved { return tab } else { return nil }
    }
}
