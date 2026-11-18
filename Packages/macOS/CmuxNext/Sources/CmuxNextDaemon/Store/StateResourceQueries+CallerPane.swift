extension StateResourceQueries {
    /// The pane where a caller's new tab opens: the pane that shows its
    /// terminal `terminal` (a `term_…` id), else the default pane of the first
    /// screen of its workspace `workspace` (a `CMUX_WORKSPACE_ID` key, in any
    /// case, with or without dashes).
    ///
    /// Returns nil when neither names a pane of this store: the caller then
    /// picks its own fallback. A browser session's `tabs.open` uses it so an
    /// agent's tabs open in the agent's workspace, never the focused one.
    ///
    /// - Parameters:
    ///   - workspace: The caller's workspace key, or nil.
    ///   - terminal: The caller's terminal id, or nil.
    /// - Returns: The caller's pane, or nil.
    public func callerPane(workspace: String?, terminal: String?) -> PaneModel? {
        nil
    }
}
