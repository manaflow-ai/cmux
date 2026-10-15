public import Foundation

/// A navigation a page is about to perform, offered to
/// ``BrowserPageUIDelegate/page(_:decidePolicyFor:)``.
public struct BrowserPageNavigationAction: Equatable, Hashable, Sendable {
    /// What started the navigation.
    public enum Trigger: Equatable, Hashable, Sendable {
        /// A link click.
        case linkActivated
        /// A form submission.
        case formSubmitted
        /// Back or forward.
        case backForward
        /// A reload.
        case reload
        /// An app or automation `load` call, or a script navigation.
        case other
    }

    /// The URL to load.
    public var url: URL
    /// The HTTP method.
    public var httpMethod: String
    /// `true` for a main-frame navigation, `false` for a subframe.
    public var isMainFrame: Bool
    /// `true` when the user's input started the navigation.
    public var isUserGesture: Bool
    /// What started the navigation.
    public var trigger: Trigger
    /// `true` when the link asked to open in a new window or tab, or a
    /// modifier key (Command, middle click) asked for one.
    public var wantsNewPage: Bool
    /// Modifier keys held when a link was activated.
    public var modifiers: BrowserPageInputEvent.Modifiers

    /// Creates a navigation action.
    /// - Parameters:
    ///   - url: The URL to load.
    ///   - httpMethod: The HTTP method; defaults to `GET`.
    ///   - isMainFrame: Whether this is a main-frame navigation; defaults to `true`.
    ///   - isUserGesture: Whether user input started it; defaults to `false`.
    ///   - trigger: What started it; defaults to ``Trigger/other``.
    ///   - wantsNewPage: Whether it asks for a new page; defaults to `false`.
    ///   - modifiers: Modifier keys held; defaults to none.
    public init(
        url: URL,
        httpMethod: String = "GET",
        isMainFrame: Bool = true,
        isUserGesture: Bool = false,
        trigger: Trigger = .other,
        wantsNewPage: Bool = false,
        modifiers: BrowserPageInputEvent.Modifiers = []
    ) {
        self.url = url
        self.httpMethod = httpMethod
        self.isMainFrame = isMainFrame
        self.isUserGesture = isUserGesture
        self.trigger = trigger
        self.wantsNewPage = wantsNewPage
        self.modifiers = modifiers
    }
}
