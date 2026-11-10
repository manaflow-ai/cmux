import CmuxNextControl

extension AppServices: BrowserTabMirrorHost {
    /// False, and no mirror, when `tab` and `pane` are not of one kind of window: nothing shows across an incognito window and a normal one (`PaneController.liveMirror`).
    func mirror(tab: String, into pane: String, select: Bool) async -> Bool {
        !windows.crossesIncognito(from: locateTabOnAnyMachine(tab).flatMap { workspaceID(of: $0.1) }, to: locatePane(pane).flatMap { workspaceID(of: $0) }) && tabMirrors.show(tab, in: pane, selecting: select ? windows.controllers.map(\.state.selection) : [])
    }
    func unmirror(tab: String, from pane: String?) async -> [String] { tabMirrors.remove(tab, from: pane) }
}
