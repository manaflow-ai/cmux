public import Foundation

/// A value snapshot for one installed extension and its toolbar action.
public struct BrowserWebExtensionPresentationItem: Identifiable, Equatable, Sendable {
    /// The stable WebKit context identifier.
    public let id: String

    /// The extension-provided display name.
    public let name: String

    /// Whether the manifest declares an action surface.
    public let hasAction: Bool

    /// Whether the action is pinned to the browser toolbar.
    public let isToolbarPinned: Bool

    /// Whether the action can run for the associated tab.
    public let isActionEnabled: Bool

    /// Whether a user click is waiting for WebKit's popup-ready callback.
    public let isAwaitingPopup: Bool

    /// The current extension-provided badge text.
    public let badgeText: String

    /// PNG data for the extension-provided action icon.
    public let iconData: Data?

    /// Creates an immutable extension presentation item.
    ///
    /// - Parameters:
    ///   - id: The stable WebKit context identifier.
    ///   - name: The extension-provided display name.
    ///   - hasAction: Whether the manifest declares an action surface.
    ///   - isToolbarPinned: Whether the action is pinned to the toolbar.
    ///   - isActionEnabled: Whether the action is enabled for the associated tab.
    ///   - isAwaitingPopup: Whether popup handoff is in progress.
    ///   - badgeText: The current badge text.
    ///   - iconData: PNG data for the extension icon.
    public init(
        id: String,
        name: String,
        hasAction: Bool,
        isToolbarPinned: Bool,
        isActionEnabled: Bool,
        isAwaitingPopup: Bool,
        badgeText: String,
        iconData: Data?
    ) {
        self.id = id
        self.name = name
        self.hasAction = hasAction
        self.isToolbarPinned = isToolbarPinned
        self.isActionEnabled = isActionEnabled
        self.isAwaitingPopup = isAwaitingPopup
        self.badgeText = badgeText
        self.iconData = iconData
    }
}
