/// The browser toolbar state owned by a single browser panel.
///
/// `hidden` is user-revealable: focusing the address bar shows the toolbar again.
/// `chromeless` is an intentional pane policy, so address-bar focus requests and
/// user omnibar toggles are ignored while that policy is active.
enum BrowserChromeVisibility: String, Codable, Equatable, Sendable {
    case visible
    case hidden
    case chromeless

    var isOmnibarVisible: Bool {
        self == .visible
    }

    var allowsAddressBarFocus: Bool {
        self != .chromeless
    }

    var allowsOmnibarToggle: Bool {
        self != .chromeless
    }

    init(omnibarVisible: Bool) {
        self = omnibarVisible ? .visible : .hidden
    }
}
