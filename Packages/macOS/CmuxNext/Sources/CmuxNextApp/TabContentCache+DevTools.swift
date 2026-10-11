import CmuxNextBrowser

extension TabContentCache: BrowserDevToolsObserving {
    func browserTab(_ tab: any BrowserTab, devToolsDidChange state: BrowserDevToolsState, focused: Bool) {
        guard let key = key(of: tab) else { return }
        onDevToolsChange?(key, state, focused)
    }
}
