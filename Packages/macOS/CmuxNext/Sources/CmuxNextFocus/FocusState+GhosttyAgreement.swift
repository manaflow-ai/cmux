/// `debug.focus`'s Ghostty check, on values only (moved out of the App's `DebugFocus`): Ghostty reports a focused
/// terminal only for the key window's resolved terminal.
extension FocusState.Resolved {
    /// The problem with the terminal tabs Ghostty reports focused (`ghostty`, app-wide) for a window whose own tabs are
    /// `ownTabs` and which is the key window or not (`isKey`); nil when Ghostty and this focus agree.
    public func ghosttyMismatch(focused ghostty: [String], ownTabs: Set<String>, isKey: Bool) -> String? {
        let here = ghostty.filter(ownTabs.contains)
        if case .terminal(_, let tab) = self, isKey { return here == [tab] ? nil : "ghostty focused \(here) != [\(tab)]" }
        return here.isEmpty ? nil : "ghostty focused \(here) while model is \(kind)\(isKey ? "" : " (window not key)")"
    }
}
