/// `debug.focus`'s Ghostty check, by the machine's rule (`Resolved::ghostty_mismatch` in
/// cmux-focus-core, through ``InputInvariants/debugWindow(_:childPage:ghostty:ownTabs:isKey:)``).
extension FocusState.Resolved {
    /// The problem with the terminal tabs Ghostty reports focused (`ghostty`, app-wide) for a window whose own tabs are
    /// `ownTabs` and which is the key window or not (`isKey`); nil when Ghostty and this focus agree.
    public func ghosttyMismatch(focused ghostty: [String], ownTabs: Set<String>, isKey: Bool) -> String? {
        InputInvariants.debugWindow(self, childPage: nil, ghostty: ghostty, ownTabs: ownTabs, isKey: isKey)?.ghosttyMismatch
    }
}
