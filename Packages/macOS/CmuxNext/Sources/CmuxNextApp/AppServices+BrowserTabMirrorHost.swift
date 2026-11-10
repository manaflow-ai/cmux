import CmuxNextControl

extension AppServices: BrowserTabMirrorHost {
    /// Tab `id` on `pane`'s machine when `pane` may mirror it (`DaemonStore.mirrorSource`: one kind of window, incognito or normal; it fails closed).
    func mirrorSource(_ id: String, for pane: PaneModel) -> (tab: TabModel, holder: PaneModel, incognito: Bool)? {
        machines.daemon(forPane: pane).store.mirrorSource(id, for: pane) { windows.isIncognito(workspace: $0) }
    }
    /// False, and no mirror, when no machine has a pane `pane` that may mirror `tab` (`mirrorSource`). A fork keeps pane ids (cmux#30755): each pane's strip asks the rule again for its own machine.
    func mirror(tab: String, into pane: String, select: Bool) async -> Bool {
        machines.daemons.contains { $0.store.pane(idOrResource: pane).map { mirrorSource(tab, for: $0) != nil } == true } && tabMirrors.show(tab, in: pane, selecting: select ? windows.controllers.map(\.state.selection) : [])
    }
    func unmirror(tab: String, from pane: String?) async -> [String] { tabMirrors.remove(tab, from: pane) }
}
