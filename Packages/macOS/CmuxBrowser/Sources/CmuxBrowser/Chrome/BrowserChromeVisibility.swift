/// The browser toolbar state owned by a single browser panel.
///
/// `hidden` is user-revealable: focusing the address bar shows the toolbar again.
/// `chromeless` is an intentional pane policy, so address-bar focus requests and
/// user omnibar toggles are ignored while that policy is active.
public enum BrowserChromeVisibility: String, Codable, Equatable, Sendable {
    /// Shows the address bar and browser toolbar.
    case visible

    /// Hides browser chrome while allowing a user action to reveal it again.
    case hidden

    /// Hides browser chrome as a fixed pane policy that user chrome actions cannot override.
    case chromeless

    /// Whether the browser should render its omnibar and toolbar controls.
    public var isOmnibarVisible: Bool {
        self == .visible
    }

    /// Whether an address-bar focus request may reveal and focus the omnibar.
    public var allowsAddressBarFocus: Bool {
        self != .chromeless
    }

    /// Whether user actions may toggle the omnibar for this panel.
    public var allowsOmnibarToggle: Bool {
        self != .chromeless
    }

    /// Maps the legacy persisted omnibar flag to the corresponding policy.
    public init(omnibarVisible: Bool) {
        self = omnibarVisible ? .visible : .hidden
    }
}
