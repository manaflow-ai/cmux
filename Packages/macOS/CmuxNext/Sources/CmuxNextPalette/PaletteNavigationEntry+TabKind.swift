extension PaletteNavigationEntry.TabKind {
    /// The kind of a tab from its record: an agent chat first, then its page, then its kind.
    ///
    /// - Parameters:
    ///   - kind: The tab's kind (`terminal`, `browser`, `remote-terminal`, ...).
    ///   - page: The internal page it shows (`markdown`, `editor`, another), nil for none.
    ///   - isAgentChat: Whether it holds an acpmux agent chat.
    public nonisolated init(kind: String, page: String?, isAgentChat: Bool) {
        if isAgentChat {
            self = .agentChat
            return
        }
        switch (page, kind) {
        case ("markdown", _): self = .markdown
        case ("editor", _): self = .file
        case (.some, _): self = .page
        case (nil, "terminal"): self = .terminal
        case (nil, "browser"): self = .browser
        case (nil, "remote-terminal"): self = .remoteTerminal
        default: self = .other
        }
    }
}
