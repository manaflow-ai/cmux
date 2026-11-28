public import AppKit
import CmuxNextPages

extension AgentPaneView {
    /// A path part's rows after the pane's own Open (a cmux file page, with its checks): Open in
    /// Text Editor, Open With ▸, Reveal in Finder and Copy Path (``LinkMenu``), for a path inside
    /// the chat's folders, or outside them when `agentPane.links.outsideRoots` is Open. Reply text
    /// names the path, so the default-app Open (which may run it) is left out, and a denied,
    /// missing or confirm-first path keeps Copy Path alone (nil).
    func pathMenuItems(_ text: String) -> [NSMenuItem]? {
        guard let resolved = model.replyPaths().resolve(text) else { return nil }
        switch resolved.place {
        case .root: break
        case .outside where model.replyLinks.settings().outsideRoots == .open: break
        default: return nil
        }
        let file = URL(fileURLWithPath: resolved.path, isDirectory: resolved.isFolder)
        let menu = LinkMenu()
        return menu.items(menu.pathRows(for: file, isDirectory: resolved.isFolder).filter { $0.kind != .open }, file: file)
    }
}

#if DEBUG
extension AgentPaneView {
    /// `debug.terminal.links agentLink` (DEBUG): opens `url` as a click on a link in an agent
    /// chat does: the gesture rule (one recorded click), then the pane's own opener (the shared
    /// link rule). True when it opened.
    public static func debugOpenClickedLink(_ url: URL) -> Bool {
        let gestures = AgentPaneUserGestures()
        gestures.record(click: true)
        return AgentPaneNavigation.openOutside(url, gestures: gestures) { routedOpenURL($0, false) }
    }
}
#endif
