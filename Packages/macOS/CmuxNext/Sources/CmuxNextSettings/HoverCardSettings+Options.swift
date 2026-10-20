public import CmuxNextDesign

extension HoverCardSettings {
    /// The workspace card's options as the sidebar reads them (`DesignSettings.workspaceHoverCard`).
    public var workspaceCardOptions: WorkspaceHoverCardOptions {
        var options = WorkspaceHoverCardOptions()
        options.layout = WorkspaceHoverCardOptions.Layout(rawValue: layout.rawValue) ?? .timeline
        options.showsTimings = showsTimings
        options.showsPrompts = showsPrompts
        options.showsWaiting = showsWaiting
        options.showsGit = showsGit
        options.showsPorts = showsPorts
        let range = WorkspaceHoverCardOptions.maxRowsRange
        options.maxRows = min(max(Int(maxRows.rounded()), range.lowerBound), range.upperBound)
        return options
    }
}
