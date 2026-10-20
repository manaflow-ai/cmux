import CmuxNextFocus

/// Chrome's per-tab omnibox focus (`OmniboxEditModel::SaveStateToTab`,
/// `RestoreState`): a browser tab left while its address bar had the
/// keyboard gets the address bar back when the user returns to the tab
/// (a tab click, a tab shortcut, a pane or workspace switch). A click in
/// the tab's page, or any other focus that lands on the tab, forgets it.
///
/// The focus core drops a chrome target when the selected tab changes
/// (`addressBar` falls back to `content`); this memory sits above it in
/// `FocusCoordinator` and asks for the address bar again once the tab is
/// back.
nonisolated struct OmnibarFocusMemory {
    /// Tabs whose address bar had the keyboard when the user left them.
    private(set) var tabs: Set<String> = []
    static let limit = 64

    /// Notes one reduction. Returns true when the reduction brought back a
    /// tab whose address bar had the keyboard: the caller asks for it.
    mutating func note(_ event: FocusEvent, before: FocusState.Resolved, after: FocusState.Resolved) -> Bool {
        if case .addressBar(_, let left) = before, after.tab != left {
            // Tabs of other workspaces stay remembered; a closed tab's id never
            // comes back, so past a bound one entry goes.
            if tabs.count >= Self.limit { tabs.removeFirst() }
            tabs.insert(left)
        }
        guard let tab = after.tab, tabs.contains(tab) else { return false }
        tabs.remove(tab)
        // Only a return to the tab restores: its page, reached from another
        // tab by a tab or pane change. A click in its page is the user's
        // choice (a responder report), and so is any other target there.
        guard case .browserPage = after, before.tab != tab, Self.isReturn(event) else { return false }
        return true
    }

    private static func isReturn(_ event: FocusEvent) -> Bool {
        switch event {
        case .selectTab, .focusPane, .topology, .expect, .dragEnded, .overlayClosed, .windowKey: true
        default: false
        }
    }
}
