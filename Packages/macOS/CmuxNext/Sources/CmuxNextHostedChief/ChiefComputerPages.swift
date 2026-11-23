public import AppKit
public import CmuxNextHomeEngine

/// The Chief's large computer pages in the pane beside Home (cmux issue 31488): one tab per conversation,
/// each tab's route its conversation, so a relaunched tab shows the same Chief. The App registers it as the
/// `chief-computer` internal page and finds, opens and closes its tabs; the views, routes and avatars are here.
@MainActor
public final class ChiefComputerPages {
    public private(set) weak var host: (any ChiefComputerHost)?
    /// The conversation the next new tab shows (set right before it opens).
    public var nextRoute: String?
    /// The page's Close: the App closes the window's profile tabs.
    public var onClose: (() -> Void)?
    private var routes: [String: String] = [:]
    private var avatars: [String: (picture: NSImage?, text: String?)] = [:]
    private var views: [String: HomeChiefProfileView] = [:]

    public init(host: any ChiefComputerHost) {
        self.host = host
    }

    /// The Home chat's avatar for its Chief, which the page shows too.
    public func setAvatar(conversation: String, picture: NSImage?, text: String?) {
        avatars[conversation] = (picture, text)
        for (key, route) in routes where route == conversation { views[key]?.setAvatar(picture: picture, text: text) }
    }

    /// The tab of `keys` that shows `conversation`, if any.
    public func key(showing conversation: String, among keys: [String]) -> String? {
        keys.first { routes[$0] == conversation }
    }

    /// Some tab that shows `conversation`.
    public func key(showing conversation: String) -> String? {
        routes.first { $0.value == conversation }?.key
    }

    /// Whether `window` has this Chief's page on screen: the chat's popup then stays away. A page
    /// parked behind another tab does not count, so the chat keeps its live view.
    public func shows(_ conversation: String, in window: NSWindow?) -> Bool {
        routes.contains { key, route in
            guard route == conversation, let view = views[key], let window else { return false }
            return view.window === window && !view.isHiddenOrHasHiddenAncestor
        }
    }

    /// A new view for the tab `key`: the profile of its conversation (or the one opening now).
    public func makeView(for key: String) -> NSView {
        let conversation = routes[key] ?? nextRoute ?? ""
        routes[key] = conversation
        let view = HomeChiefProfileView()
        views[key] = view
        guard let host else { return view }
        ChiefComputerWiring.wirePage(view, host: host, conversation: conversation)
        view.onClose = { [weak self] in self?.onClose?() }
        if let avatar = avatars[conversation] { view.setAvatar(picture: avatar.picture, text: avatar.text) }
        return view
    }

    public func tabClosed(_ key: String) {
        routes[key] = nil
        views[key] = nil
    }

    public func route(for key: String) -> String? { routes[key] }

    public func restore(_ route: String, for key: String) {
        routes[key] = route
    }
}
