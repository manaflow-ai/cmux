#if DEBUG
import Bonsplit

// MARK: - Split debug descriptions

extension Workspace {
    /// Short panel kind for a bonsplit tab in split debug events.
    func debugSplitPanelKind(forTabId tabId: TabID) -> String {
        guard let panelId = panelIdFromSurfaceId(tabId),
              let panel = panels[panelId] else { return "placeholder" }
        if panel is TerminalPanel { return "terminal" }
        if panel is BrowserPanel { return "browser" }
        return String(describing: type(of: panel))
    }

    /// One letter per tab in `paneId`, in tab order, for split debug events.
    func debugSplitPaneKindSummary(_ controller: BonsplitController, paneId: PaneID) -> String {
        let tabs = controller.tabs(inPane: paneId)
        guard !tabs.isEmpty else { return "-" }
        return tabs.map { tab in
            String(debugSplitPanelKind(forTabId: tab.id).prefix(1))
        }.joined(separator: ",")
    }
}
#endif
