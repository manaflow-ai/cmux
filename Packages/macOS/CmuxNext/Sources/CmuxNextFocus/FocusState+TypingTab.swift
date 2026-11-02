extension FocusState {
    /// The focused terminal's tab; nil when the focus is not on a terminal.
    public var terminalTab: String? {
        if case .terminal(_, let tab) = resolved { return tab } else { return nil }
    }
}
