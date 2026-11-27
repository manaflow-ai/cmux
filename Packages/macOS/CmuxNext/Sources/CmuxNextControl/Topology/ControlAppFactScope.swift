public import CmuxNextDaemon

/// The workspaces whose app facts can differ from their daemon facts in one
/// control snapshot publish: the facts `ControlPageFacts` and the publisher's
/// `selectedTab` answer, which Observation does not track.
///
/// Every other workspace has no shown tab, no app-only page tab and no store
/// page tab, so its control value is its cached daemon value as is. With a
/// scope, a publish maps only the workspaces that changed or are in it,
/// instead of every workspace (sidebar churn bench, 400 workspaces).
///
/// The scope must be complete: a pane outside it that has a shown tab or an
/// app-only page tab is listed without them.
public struct ControlAppFactScope {
    /// Workspaces a window has mounted: their panes can report a shown tab.
    public var shown: [WorkspaceModel]
    /// Ids (`PaneModel.id`) of the panes that have app-only page tabs.
    public var paneIDs: [String]

    /// - Parameters:
    ///   - shown: workspaces a window has mounted.
    ///   - paneIDs: ids of the panes with app-only page tabs.
    public init(shown: [WorkspaceModel] = [], paneIDs: [String] = []) {
        self.shown = shown
        self.paneIDs = paneIDs
    }
}
