import CmuxNextControl

extension AppServices: BrowserTabMirrorHost {
    func mirror(tab: String, into pane: String, select: Bool) async -> Bool { tabMirrors.show(tab, in: pane, selecting: select ? windows.controllers.map(\.state.selection) : []) }
    func unmirror(tab: String, from pane: String?) async -> [String] { tabMirrors.remove(tab, from: pane) }
}
