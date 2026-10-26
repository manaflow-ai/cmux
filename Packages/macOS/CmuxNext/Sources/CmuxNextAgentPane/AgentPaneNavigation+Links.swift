import CmuxNextPages
import Foundation

extension AgentPaneNavigation {
    /// Opens a clicked link outside the pane: only an http(s) URL with a host and no user name or
    /// password, and only by spending a real user gesture in the pane (``AgentPaneUserGestures``,
    /// which page script cannot record), so WebKit's link-activated flag is never the only proof.
    /// True when it opened.
    /// A cmux app link (``isCmuxAppLink(_:)``) spends the gesture too and goes to `openApp`, the
    /// app's own `link.open` (``LinkRouter/appLink``), never to the system.
    @MainActor static func openOutside(_ url: URL, gestures: AgentPaneUserGestures, open: (URL) -> Void,
                                       openApp: (URL) -> Bool = { LinkRouter.shared.appLink($0) }) -> Bool {
        if isCmuxAppLink(url) {
            guard gestures.consume() else { return false }
            return openApp(url)
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.user == nil, url.password == nil, url.host?.isEmpty == false,
              gestures.consume() else { return false }
        open(url)
        return true
    }
}

extension AgentPaneNavigation {
    /// Whether `url` is a cmux app link a reply may draw and a click hands to the app: the `cmux`
    /// scheme or a build's `cmux-…` one, a workspace, pane, tab, session, Chief or agent host, and no user
    /// name, password or port. The app parses the ids again (DeepLink.parse) and opens nothing else.
    /// The pane's own schemes are never one (media-safety R7): `cmux-page` (its page and media) and
    /// `cmux-agent` (the origin acpmux allows, ``AcpmuxConnection/paneOrigin``).
    nonisolated static func isCmuxAppLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "cmux" || scheme.hasPrefix("cmux-"),
              scheme != "cmux-agent", scheme != PageDescriptor.scheme,
              url.user == nil, url.password == nil, url.port == nil,
              let host = url.host?.lowercased() else { return false }
        return ["workspace", "pane", "tab", "session", "chief", "agent"].contains(host)
    }
}
