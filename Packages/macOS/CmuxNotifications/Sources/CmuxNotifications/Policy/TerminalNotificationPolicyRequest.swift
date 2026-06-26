public import Foundation

/// The inputs used to build the initial ``TerminalNotificationPolicyEnvelope``
/// before policy hooks run: the owning workspace/surface/panel ids, the
/// notification text, the originating working directory, and the app/panel
/// focus state at the time the notification was raised.
public struct TerminalNotificationPolicyRequest: Sendable {
    /// The id of the workspace (tab) that owns the notification.
    public let tabId: UUID
    /// The id of the surface within the workspace, when scoped to one surface.
    public let surfaceId: UUID?
    /// The id of the panel within the workspace, when scoped to one panel.
    public let panelId: UUID?
    /// The notification title.
    public let title: String
    /// The notification subtitle.
    public let subtitle: String
    /// The notification body text.
    public let body: String
    /// The working directory associated with the notification, if any.
    public let cwd: String?
    /// Whether the application was focused when the notification was raised.
    public let isAppFocused: Bool
    /// Whether the owning panel was focused when the notification was raised.
    public let isFocusedPanel: Bool

    /// Creates a notification-policy request.
    public init(
        tabId: UUID,
        surfaceId: UUID?,
        panelId: UUID? = nil,
        title: String,
        subtitle: String,
        body: String,
        cwd: String?,
        isAppFocused: Bool,
        isFocusedPanel: Bool
    ) {
        self.tabId = tabId
        self.surfaceId = surfaceId
        self.panelId = panelId
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.cwd = cwd
        self.isAppFocused = isAppFocused
        self.isFocusedPanel = isFocusedPanel
    }
}
