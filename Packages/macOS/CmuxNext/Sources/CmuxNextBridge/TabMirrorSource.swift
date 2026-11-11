public import CmuxNextDaemon

extension DaemonStore {
    /// Tab `id` of this store with its pane and their kind of window (true: incognito), when `pane` (a pane of this
    /// store) may mirror it (`TabMirrors`): the two are in windows of one kind. Nil for a tab this store does not
    /// have, across an incognito window and a normal one, and when a side has no known workspace (it fails closed):
    /// nothing moves between an incognito window and a normal one.
    ///
    /// It is the one answer for a mirror request, the pane's strip, the page it presents and each reader of a
    /// pane's mirrors (the control topology, the agent cursor), so that they can not disagree.
    ///
    /// - Parameter isIncognito: the app's answer for a workspace (its window's kind, or its `ephemeral` flag).
    public func mirrorSource(_ id: String, for pane: PaneModel,
                             isIncognito: (WorkspaceModel) -> Bool) -> (tab: TabModel, holder: PaneModel, incognito: Bool)? {
        guard let tab = tab(idOrResource: id), let holder = self.pane(holding: tab),
              let from = workspace(containing: holder.handle), let into = workspace(containing: pane.handle),
              case let secret = isIncognito(from), secret == isIncognito(into) else { return nil }
        return (tab, holder, secret)
    }
}
