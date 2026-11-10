import CmuxNextControl

extension AppServices: BrowserTabMirrorHost {
    /// Tab `id` on `pane`'s machine when `pane` may mirror it (`DaemonStore.mirrorSource`: one kind of window, incognito or normal; it fails closed).
    func mirrorSource(_ id: String, for pane: PaneModel) -> (tab: TabModel, holder: PaneModel, incognito: Bool)? {
        machines.daemon(forPane: pane).store.mirrorSource(id, for: pane) { windows.isIncognito(workspace: $0) }
    }
    /// False, and no mirror, when the app has no such pane or the pane may not mirror `tab` (`mirrorSource`).
    func mirror(tab: String, into pane: String, select: Bool) async -> Bool {
        locatePane(pane).map { mirrorSource(tab, for: $0) != nil } == true && tabMirrors.show(tab, in: pane, selecting: select ? windows.controllers.map(\.state.selection) : [])
    }
    func unmirror(tab: String, from pane: String?) async -> [String] { tabMirrors.remove(tab, from: pane) }
}
